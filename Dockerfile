FROM runpod/comfyui:latest

# runpod/comfyui:latest is a POD image: its entrypoint starts SSH/FileBrowser/Jupyter and never runs
# a serverless handler, so jobs queue forever. Clear it and run the volume's boot script, which
# starts ComfyUI from /runpod-volume and then execs handler.py (runpod.serverless.start).
ENTRYPOINT []
CMD ["bash", "/runpod-volume/pipeline/deploy/start.sh"]
