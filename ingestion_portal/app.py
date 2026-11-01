import os
import re
import glob
import json
import time
import shutil
import threading
from typing import List, Optional
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, BackgroundTasks
from fastapi.responses import HTMLResponse, JSONResponse, FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from jinja2 import Environment, FileSystemLoader

from worker import process_route_pipeline

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_DIR = os.path.join(BASE_DIR, "raw-uncleaned")
MINED_DIR = os.path.join(BASE_DIR, "all_routes_mined_network_repaired")

os.makedirs(RAW_DIR, exist_ok=True)
os.makedirs(MINED_DIR, exist_ok=True)

app = FastAPI(
    title="FlexiTransit-AI Ingestion Portal",
    description="Isolated GPS Trajectory Ingestion Micro-Service (Port 5001)",
    version="1.0.0"
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Setup Jinja2 templates
TEMPLATES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")
os.makedirs(TEMPLATES_DIR, exist_ok=True)
jinja_env = Environment(loader=FileSystemLoader(TEMPLATES_DIR))

# Pipeline execution state storage
pipeline_jobs = {}
pipeline_lock = threading.Lock()


def sanitize_route_name(name: str) -> str:
    """Sanitize route names: lowercase, hyphens instead of spaces, remove non-alphanumeric."""
    if not name:
        return "feeder-route"
    name = name.strip().lower()
    name = re.sub(r'[\s_]+', '-', name)
    name = re.sub(r'[^a-z0-9\-]', '', name)
    name = re.sub(r'-+', '-', name).strip('-')
    return name or "feeder-route"


def run_pipeline_worker(route_name: str):
    """Executes the DBSCAN stop mining and corridor snapping in the background."""
    raw_folder = os.path.join(RAW_DIR, route_name)
    with pipeline_lock:
        pipeline_jobs[route_name] = {
            "status": "running",
            "logs": [],
            "started_at": time.time(),
            "success": False,
            "message": ""
        }

    def log_cb(msg: str):
        with pipeline_lock:
            if route_name in pipeline_jobs:
                pipeline_jobs[route_name]["logs"].append(msg)

    success, msg = process_route_pipeline(
        route_name=route_name,
        raw_folder=raw_folder,
        output_base=MINED_DIR,
        log_callback=log_cb
    )

    with pipeline_lock:
        if route_name in pipeline_jobs:
            pipeline_jobs[route_name]["status"] = "completed" if success else "error"
            pipeline_jobs[route_name]["success"] = success
            pipeline_jobs[route_name]["message"] = msg
            pipeline_jobs[route_name]["finished_at"] = time.time()


@app.get("/", response_class=HTMLResponse)
async def get_dashboard():
    """Serves the standalone upload portal dashboard."""
    template = jinja_env.get_template("index.html")
    return HTMLResponse(template.render())


@app.get("/api/routes")
async def list_routes():
    """Returns scanned routes from raw-uncleaned/ and all_routes_mined_network_repaired/."""
    routes_dict = {}

    # 1. Scan raw-uncleaned/
    if os.path.exists(RAW_DIR):
        for entry in sorted(os.listdir(RAW_DIR)):
            p = os.path.join(RAW_DIR, entry)
            if os.path.isdir(p):
                csvs = glob.glob(os.path.join(p, "*.csv"))
                routes_dict[entry] = {
                    "route_name": entry,
                    "raw_count": len(csvs),
                    "is_mined": False,
                    "stops_count": 0,
                    "distance_m": 0.0
                }

    # 2. Scan all_routes_mined_network_repaired/
    if os.path.exists(MINED_DIR):
        for entry in sorted(os.listdir(MINED_DIR)):
            p = os.path.join(MINED_DIR, entry)
            if os.path.isdir(p):
                if entry not in routes_dict:
                    raw_p = os.path.join(RAW_DIR, entry)
                    csvs = glob.glob(os.path.join(raw_p, "*.csv")) if os.path.exists(raw_p) else []
                    routes_dict[entry] = {
                        "route_name": entry,
                        "raw_count": len(csvs),
                        "is_mined": False,
                        "stops_count": 0,
                        "distance_m": 0.0
                    }

                # Check if mined
                vstops_path = os.path.join(p, "virtual_stops.geojson")
                meta_path = os.path.join(p, "route_metadata.json")
                if os.path.exists(vstops_path):
                    routes_dict[entry]["is_mined"] = True
                    if os.path.exists(meta_path):
                        try:
                            with open(meta_path, "r", encoding="utf-8") as f:
                                meta = json.load(f)
                                routes_dict[entry]["stops_count"] = meta.get("total_stops", meta.get("total_detected_stops", 0))
                                routes_dict[entry]["distance_m"] = meta.get("corridor_length_m", meta.get("corridor_distance_m", 0.0))
                        except Exception:
                            pass

    return {
        "routes": list(routes_dict.values()),
        "total": len(routes_dict)
    }


@app.get("/api/route-status/{route_name}")
async def get_route_status(route_name: str):
    """Detailed file and processing status for a specific route."""
    clean_name = sanitize_route_name(route_name)
    route_raw_dir = os.path.join(RAW_DIR, clean_name)
    raw_files = []
    if os.path.exists(route_raw_dir):
        for f in sorted(glob.glob(os.path.join(route_raw_dir, "*.csv"))):
            raw_files.append({
                "name": os.path.basename(f),
                "size_bytes": os.path.getsize(f)
            })

    target_mined = os.path.join(MINED_DIR, clean_name)
    is_mined = os.path.exists(os.path.join(target_mined, "virtual_stops.geojson"))
    metadata = None
    if is_mined and os.path.exists(os.path.join(target_mined, "route_metadata.json")):
        try:
            with open(os.path.join(target_mined, "route_metadata.json"), "r", encoding="utf-8") as f:
                metadata = json.load(f)
        except Exception:
            pass

    job = pipeline_jobs.get(clean_name, {
        "status": "completed" if is_mined else "idle",
        "logs": [],
        "success": is_mined,
        "message": ""
    })

    return {
        "route_name": clean_name,
        "raw_path": f"raw-uncleaned/{clean_name}",
        "raw_count": len(raw_files),
        "files": raw_files,
        "is_mined": is_mined,
        "metadata": metadata,
        "pipeline_state": job.get("status", "idle"),
        "logs": job.get("logs", []),
        "success": job.get("success", False),
        "message": job.get("message", "")
    }


@app.post("/api/upload")
async def upload_trajectories(
    route_name: str = Form(...),
    route_mode: str = Form("new"),
    files: List[UploadFile] = File(...),
    sync_execution: bool = False
):
    """
    Accepts raw trajectory CSVs, saves them to raw-uncleaned/<route_name>/,
    evaluates file count threshold (> 3), and triggers mining pipeline if met.
    """
    clean_name = sanitize_route_name(route_name)
    route_raw_dir = os.path.join(RAW_DIR, clean_name)
    os.makedirs(route_raw_dir, exist_ok=True)

    saved_files = []
    for upload in files:
        if not upload.filename:
            continue
        # Ensure .csv extension
        fname = os.path.basename(upload.filename)
        if not fname.lower().endswith(".csv"):
            fname = f"{fname}.csv"

        dest_path = os.path.join(route_raw_dir, fname)
        content = await upload.read()
        with open(dest_path, "wb") as f:
            f.write(content)
        saved_files.append({"name": fname, "size": len(content)})

    # Evaluate total trip files in staging folder
    csv_paths = sorted(glob.glob(os.path.join(route_raw_dir, "*.csv")))
    total_trips = len(csv_paths)

    if total_trips <= 3:
        return {
            "success": True,
            "route_name": clean_name,
            "trip_count": total_trips,
            "threshold_met": False,
            "status": "awaiting",
            "message": f"Uploaded {total_trips} trips. A minimum of 4 trips (>3) are required for DBSCAN stop mining. Awaiting more trip logs.",
            "staging_path": f"raw-uncleaned/{clean_name}",
            "saved_in_batch": len(saved_files),
            "files": [os.path.basename(p) for p in csv_paths]
        }
    else:
        # Threshold met (>3 trips). Trigger pipeline!
        if sync_execution:
            # Synchronous execution (useful for deterministic tests/scripts)
            run_pipeline_worker(clean_name)
            job = pipeline_jobs.get(clean_name, {})
            return {
                "success": job.get("success", True),
                "route_name": clean_name,
                "trip_count": total_trips,
                "threshold_met": True,
                "status": job.get("status", "completed"),
                "message": job.get("message", "Pipeline execution completed."),
                "staging_path": f"raw-uncleaned/{clean_name}",
                "output_path": f"all_routes_mined_network_repaired/{clean_name}",
                "logs": job.get("logs", [])
            }
        else:
            # Asynchronous background execution
            th = threading.Thread(target=run_pipeline_worker, args=(clean_name,), daemon=True)
            th.start()

            return {
                "success": True,
                "route_name": clean_name,
                "trip_count": total_trips,
                "threshold_met": True,
                "status": "running",
                "message": "Trigger threshold met (>3 trips). Executing DBSCAN stop mining and centerline snapping pipeline...",
                "staging_path": f"raw-uncleaned/{clean_name}",
                "output_path": f"all_routes_mined_network_repaired/{clean_name}",
                "files": [os.path.basename(p) for p in csv_paths]
            }


@app.get("/api/pipeline-status/{route_name}")
async def get_pipeline_logs(route_name: str):
    """Poll pipeline execution logs and status."""
    clean_name = sanitize_route_name(route_name)
    target_mined = os.path.join(MINED_DIR, clean_name)
    is_mined = os.path.exists(os.path.join(target_mined, "virtual_stops.geojson"))
    
    with pipeline_lock:
        job = pipeline_jobs.get(clean_name, {
            "status": "completed" if is_mined else "idle",
            "logs": [],
            "success": is_mined,
            "message": ""
        })

    metadata = None
    if is_mined and os.path.exists(os.path.join(target_mined, "route_metadata.json")):
        try:
            with open(os.path.join(target_mined, "route_metadata.json"), "r", encoding="utf-8") as f:
                metadata = json.load(f)
        except Exception:
            pass

    return {
        "route_name": clean_name,
        "status": job.get("status", "idle"),
        "logs": job.get("logs", []),
        "success": job.get("success", False),
        "message": job.get("message", ""),
        "is_mined": is_mined,
        "metadata": metadata
    }


@app.get("/api/routes/{route_name}/deliverables")
async def get_route_deliverables(route_name: str):
    """Returns deliverables files content or status for preview."""
    clean_name = sanitize_route_name(route_name)
    corridor_dir = os.path.join(MINED_DIR, clean_name)
    if not os.path.exists(corridor_dir):
        raise HTTPException(status_code=404, detail=f"Route '{clean_name}' deliverables not found.")

    res = {
        "route_name": clean_name,
        "files_available": os.listdir(corridor_dir)
    }

    # Virtual stops
    vstops_file = os.path.join(corridor_dir, "virtual_stops.geojson")
    if os.path.exists(vstops_file):
        with open(vstops_file, "r", encoding="utf-8") as f:
            res["virtual_stops"] = json.load(f)

    # Route metadata
    meta_file = os.path.join(corridor_dir, "route_metadata.json")
    if os.path.exists(meta_file):
        with open(meta_file, "r", encoding="utf-8") as f:
            res["metadata"] = json.load(f)

    # Summary CSV
    summary_csv = os.path.join(corridor_dir, "virtual_stops_summary.csv")
    if os.path.exists(summary_csv):
        with open(summary_csv, "r", encoding="utf-8") as f:
            res["summary_csv_text"] = f.read()

    return res


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app:app", host="127.0.0.1", port=5001, reload=False)
