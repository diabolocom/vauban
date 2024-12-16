import yaml


def get_vauban_job(ulid, image, command):
    job = f"""
apiVersion: batch/v1
kind: Job
metadata:
  name: vauban-{ulid.lower()}
spec:
  activeDeadlineSeconds: 10800  # 3 hours
  ttlSecondsAfterFinished: 86400  # a day
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
          - name: VAUBAN_BUILD_JOB_ULID
            value: "{ulid}"
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
    command = [
        "bash",
        "-c",
        f"cp /opt/vauban/.secrets.env /srv ; cp /opt/vauban/ansible_id_ed25519 /srv/ansible-ro ; chmod 0600 /srv/ansible-ro ; mkdir -p /root/.ssh ; cp /opt/vauban/id_ed25519 /root/.ssh/ ; chmod 0600 /root/.ssh/id_ed25519 ; export VAUBAN_KUBERNETES_ENGINE_PUB_KEY=\"$(cat /opt/vauban/id_ed25519.pub)\" ; {' '.join(command)}",
    ]
    job_manifest["spec"]["template"]["spec"]["containers"][0]["command"] = command
    return job_manifest
