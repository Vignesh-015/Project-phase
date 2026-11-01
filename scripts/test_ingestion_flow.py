import os
import json
import uuid
import urllib.request

def upload_trips(route_name, file_paths, sync=False):
    boundary = '----WebKitFormBoundary' + uuid.uuid4().hex
    lines = []
    
    # Form fields
    for k, v in [('route_name', route_name), ('route_mode', 'new')]:
        lines.append(f'--{boundary}'.encode('utf-8'))
        lines.append(f'Content-Disposition: form-data; name="{k}"'.encode('utf-8'))
        lines.append(b'')
        lines.append(v.encode('utf-8'))
        
    # File attachments
    for fpath in file_paths:
        fname = os.path.basename(fpath)
        with open(fpath, 'rb') as f:
            data = f.read()
        lines.append(f'--{boundary}'.encode('utf-8'))
        lines.append(f'Content-Disposition: form-data; name="files"; filename="{fname}"'.encode('utf-8'))
        lines.append(b'Content-Type: text/csv')
        lines.append(b'')
        lines.append(data)
        
    lines.append(f'--{boundary}--'.encode('utf-8'))
    lines.append(b'')
    body = b'\r\n'.join(lines)
    
    url = f'http://127.0.0.1:5001/api/upload{"?sync_execution=true" if sync else ""}'
    req = urllib.request.Request(url, data=body)
    req.add_header('Content-Type', f'multipart/form-data; boundary={boundary}')
    
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode('utf-8'))

if __name__ == '__main__':
    print("=== Step 1: Uploading 2 CSV trips for 'test-tambaram' ===")
    res1 = upload_trips('test-tambaram', ['test_fixtures/trip1.csv', 'test_fixtures/trip2.csv'])
    print("Response:")
    print(json.dumps(res1, indent=2))
    
    # Verify staging files
    staging_dir = os.path.join('raw-uncleaned', 'test-tambaram')
    if os.path.exists(staging_dir):
        files = os.listdir(staging_dir)
        print(f"\nFiles in {staging_dir}: {files} (Count: {len(files)})")
    else:
        print(f"\nError: {staging_dir} does not exist!")
