# ComfyUI + SageAttention + cu128 PyTorch + ttyd + CopyParty
# Base: plain Ubuntu to avoid pinning CUDA in the image — we’ll use PyTorch cu128 wheels (bundled CUDA runtime)
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    UV_LOCALE=C.UTF-8 \
    LANG=C.UTF-8

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3.11-dev \
    git curl wget ca-certificates gnupg \
    build-essential pkg-config ninja-build \
    libglib2.0-0 libsm6 libxrender1 libxext6 \
    tini unzip p7zip-full \
    # web terminal (ttyd) + copyparty
    cmake libjson-c-dev libwebsockets-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# symlink python3
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 && \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

# Build and install ttyd (fast web terminal)
WORKDIR /opt
RUN git clone --depth 1 https://github.com/tsl0922/ttyd.git && \
    cd ttyd && mkdir build && cd build && cmake .. && make -j$(nproc) && make install

# Install CopyParty (file manager/uploader)
RUN pip install --no-cache-dir copyparty

# Create runtime user
RUN useradd -m -u 1000 appuser
USER appuser
WORKDIR /home/appuser

# Python venv
RUN python -m venv /home/appuser/venv
ENV PATH=/home/appuser/venv/bin:$PATH

# Install PyTorch with CUDA 12.8 wheels (Blackwell-ready)
# If PyTorch bumps, just change the version here. 2.7+ supports Blackwell.
# NOTE: host must have a recent NVIDIA driver; wheels bundle CUDA runtime.
RUN pip install --upgrade pip && \
    pip install --index-url https://download.pytorch.org/whl/cu128 \
      torch torchvision torchaudio --extra-index-url https://pypi.org/simple

# ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git && \
    pip install --no-cache-dir -r ComfyUI/requirements.txt

# ComfyUI Manager (optional but handy)
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git ComfyUI/custom_nodes/ComfyUI-Manager || true

# SageAttention (Blackwell-ready kernels; requires CUDA >= 12.8 which the cu128 wheels bring)
# Prefer the released wheel if present; otherwise build from source
# Try pip wheel first (keeps build time down); fall back to source build.
RUN (pip install --no-build-isolation "sageattention==2.2.0" || \
    (git clone https://github.com/thu-ml/SageAttention.git && \
     cd SageAttention && \
     python setup.py install))

# Ports
# 8188 = ComfyUI, 7681 = ttyd, 3923 = CopyParty
EXPOSE 8188 7681 3923

# Runtime dirs
RUN mkdir -p /home/appuser/models/checkpoints /home/appuser/models/loras /home/appuser/ComfyUI/user/default

# env knobs
ENV CIVITAI_TOKEN="" \
    LORAS_IDS="" \
    LORAS_CHECKPOINTS="" \
    CHECKPOINT_DIR="/home/appuser/models/checkpoints" \
    LORA_DIR="/home/appuser/models/loras" \
    COMFY_EXTRA_ARGS="" \
    USE_SAGEATTN="1" \
    COPY_PARTY_ROOT="/home/appuser" \
    COPY_PARTY_ARGS="--no-dotfiles --nocgi --auth guest::rw"

# Helper downloader script
COPY --chown=appuser:appuser downloader.sh /home/appuser/downloader.sh
RUN chmod +x /home/appuser/downloader.sh

# Start script
COPY --chown=appuser:appuser start.sh /home/appuser/start.sh
RUN chmod +x /home/appuser/start.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/home/appuser/start.sh"]
