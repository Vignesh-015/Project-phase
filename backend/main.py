"""
FlexiTransit-AI: FastAPI Backend Server
Serves virtual stop mining results and multi-modal route computation.
"""

import os
import json
import httpx
from typing import Optional
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Body
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from dotenv import load_dotenv

# Load environment variables from .env
load_dotenv()
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
OPENROUTER_BASE_URL = os.getenv("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")

from router import compute_routes, network


# ─────────────────────────────────────────────────────────────────────────────
# APP STATE
# ─────────────────────────────────────────────────────────────────────────────
class AppState:
    telemetry_buffer: list = []


app_state = AppState()


# ─────────────────────────────────────────────────────────────────────────────
# LIFESPAN
# ─────────────────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    print("[STARTUP] FlexiTransit-AI backend ready!")
    yield
    print("[SHUTDOWN] Bye!")


# ─────────────────────────────────────────────────────────────────────────────
# APP INIT
# ─────────────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="FlexiTransit-AI API",
    description="Intelligent Multi-Modal Transit Engine for Chennai",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─────────────────────────────────────────────────────────────────────────────
# PYDANTIC MODELS
# ─────────────────────────────────────────────────────────────────────────────
class TelemetryPoint(BaseModel):
    trace_id: str
    device_id: str
    latitude: float
    longitude: float
    speed: float
    bearing: float
    timestamp: str
    source_type: str = "FLUTTER_PWA"


class TelemetryBatch(BaseModel):
    points: list[TelemetryPoint]


class AIQueryRequest(BaseModel):
    query: str


# ─────────────────────────────────────────────────────────────────────────────
# ENDPOINTS
# ─────────────────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health_check():
    """Heartbeat endpoint."""
    return {
        "status": "healthy",
        "service": "FlexiTransit-AI",
        "version": "1.0.0",
        "telemetry_buffer_size": len(app_state.telemetry_buffer),
        "openrouter_configured": bool(OPENROUTER_API_KEY),
    }


@app.post("/api/ai/natural-query")
async def process_natural_query(req: AIQueryRequest):
    """
    OpenRouter AI endpoint for natural language query interpretation.
    Extracts origin and destination intent without inventing coordinates.
    """
    if not OPENROUTER_API_KEY:
        # Fallback regex/string heuristic if API key is unconfigured
        return parse_query_heuristically(req.query)

    prompt = f"""You are a geospatial query intent parser for a navigation app.
The user input is: "{req.query}"

Extract the starting point (source) and destination from the user query.
Return strictly a valid JSON object in this exact format:
{{
  "source": "extracted source location name or empty string if not mentioned",
  "destination": "extracted destination location name or empty string if not mentioned"
}}
Do NOT output markdown, code blocks, or extra text. Output ONLY valid JSON.
"""

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.post(
                f"{OPENROUTER_BASE_URL}/chat/completions",
                headers={
                    "Authorization": f"Bearer {OPENROUTER_API_KEY}",
                    "Content-Type": "application/json",
                    "HTTP-Referer": "https://flexitransit.org",
                    "X-Title": "FlexiTransit-AI",
                },
                json={
                    "model": "openai/gpt-4o-mini",
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.1,
                },
            )

        if resp.status_code == 200:
            data = resp.json()
            content = data["choices"][0]["message"]["content"].strip()
            # Remove possible markdown fences ```json ... ```
            if content.startswith("```"):
                content = content.replace("```json", "").replace("```", "").strip()
            parsed = json.loads(content)
            return {
                "success": True,
                "source": parsed.get("source", ""),
                "destination": parsed.get("destination", ""),
                "raw_query": req.query,
            }
        else:
            return parse_query_heuristically(req.query)
    except Exception as e:
        print(f"[OPENROUTER ERROR] {e}")
        return parse_query_heuristically(req.query)


def parse_query_heuristically(query: str) -> dict:
    """Fallback simple parser for natural language intent."""
    q = query.lower()
    source, dest = "", ""
    if " from " in q and " to " in q:
        parts = q.split(" from ")
        if len(parts) > 1:
            sub = parts[1].split(" to ")
            source = sub[0].strip()
            if len(sub) > 1:
                dest = sub[1].strip()
    elif " to " in q:
        parts = q.split(" to ")
        source = parts[0].replace("find a route", "").replace("take me", "").replace("route", "").strip()
        dest = parts[1].strip()
    else:
        dest = query.strip()

    return {
        "success": True,
        "source": source.title(),
        "destination": dest.title(),
        "raw_query": query,
    }




@app.post("/api/telemetry/ingest")
async def ingest_telemetry(batch: TelemetryBatch):
    """
    Accepts live GPS telemetry batches from the Flutter driver PWA.
    Points are buffered in memory (can be persisted to DB in production).
    """
    app_state.telemetry_buffer.extend([p.model_dump() for p in batch.points])
    return {
        "accepted": len(batch.points),
        "total_buffered": len(app_state.telemetry_buffer),
        "message": f"Ingested {len(batch.points)} telemetry points successfully."
    }


@app.get("/api/route")
async def get_route(
    origin_lat: float,
    origin_lon: float,
    dest_lat: float,
    dest_lon: float,
    dep_time: Optional[str] = "08:00"
):
    """
    Computes and returns 3 multi-modal route options:
    1. ⭐ Multi-Modal (Shared Auto + Metro) — Best Value
    2. 💰 Direct Bus (MTC) — Budget
    3. ⚡ Private Cab — Fastest

    Returns GeoJSON-compatible route objects with polylines, steps, fares, times.
    """
    try:
        routes = compute_routes(
            origin_lat=origin_lat,
            origin_lon=origin_lon,
            dest_lat=dest_lat,
            dest_lon=dest_lon,
            dep_time=dep_time
        )
        return {
            "origin": {"lat": origin_lat, "lon": origin_lon},
            "destination": {"lat": dest_lat, "lon": dest_lon},
            "departure_time": dep_time,
            "options": routes,
            "total_options": len(routes),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Routing error: {str(e)}")



@app.get("/api/telemetry/buffer")
async def get_telemetry_buffer():
    """Return buffered telemetry points for debugging."""
    return {
        "count": len(app_state.telemetry_buffer),
        "points": app_state.telemetry_buffer[-50:]  # Last 50 points
    }


@app.post("/api/reload-network")
async def reload_network():
    """Reloads the transit graph dynamically from all_routes_mined_network_repaired."""
    try:
        network.nodes.clear()
        network.edges.clear()
        network.corridor_stops.clear()
        network.corridor_polylines.clear()
        network.metro_shapes.clear()
        network.spatial_tree = None
        network.stop_index_map.clear()
        network.loaded = False
        network.load_network()
        return {
            "success": True,
            "message": "Transit network successfully reloaded",
            "nodes_count": len(network.nodes),
            "corridors": list(network.corridor_polylines.keys()),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Reload failed: {str(e)}")


# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
