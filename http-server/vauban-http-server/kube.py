import yaml


def get_vauban_job(ulid, image, command):
    job = f"""
apiVersion: batch/v1
kind: Job
metadata:
  name: vauban-{ulid}
spec:
  template:
    metadata:
      labels:
        vauban.corp.dblc.io/vauban-job-id: {ulid}
    spec:
      containers:
      - name: vauban
        image: {image}
        imagePullPolicy: Always
      restartPolicy: Never
  backoffLimit: 1
"""
    job_manifest = yaml.safe_load(job)
    job_manifest['spec']['template']['spec']['containers'][0]['command'] = command
    return job_manifest
