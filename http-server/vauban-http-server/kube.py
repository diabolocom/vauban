import yaml


def get_vauban_job(ulid, image, command):
    job = f"""
apiVersion: batch/v1
kind: Job
metadata:
  name: vauban-{ulid.lower()}
spec:
  activeDeadlineSeconds: 7200
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        vauban.corp.dblc.io/vauban-job-id: {ulid}
    spec:
      containers:
      - name: vauban
        image: {image}
        imagePullPolicy: Always
        env:
          - name: PYTHONUNBUFFERED
            value: "1"
        volumeMounts:
          - mountPath: "/opt/vauban"
            name: secrets
            readOnly: true
      restartPolicy: Never
      serviceAccountName: vauban
      volumes:
        - name: secrets
          secret:
            secretName: vauban-main
  backoffLimit: 1
"""
    job_manifest = yaml.safe_load(job)
    command = ["bash", "-c", f"cp /opt/vauban/.secrets.env /srv ; cp /opt/vauban/* /srv ; {' '.join(command)}"]
    job_manifest['spec']['template']['spec']['containers'][0]['command'] = command
    return job_manifest
