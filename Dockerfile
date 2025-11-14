# ComfyUI + SageAttention + cu128 PyTorch + ttyd + CopyParty
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    LANG=C.UTF-8

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-dev python3-pip \
    git curl wget ca-certificates gnupg \
    build-essential pkg-config ninja-build \
    libglib2.0-0 libsm6 libxrender1 libxext6 \
    tini unzip p7zip-full \
    cmake libjson-c-dev libwebsockets-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

# Install CUDA toolkit (for building SageAttention and other extensions).
# Default to CUDA 12.8 (Blackwell-ready), but allow overriding at build time
# so RunPod users can match their chosen runtime image (e.g., 12.9).
ARG CUDA_TOOLKIT_PKG="cuda-toolkit-12-8"
RUN wget -qO /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
 && dpkg -i /tmp/cuda-keyring.deb \
 && rm /tmp/cuda-keyring.deb \
 && wget -qO /etc/apt/preferences.d/cuda-repository-pin-600 https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-ubuntu2404.pin \
 && apt-get update \
 && apt-get install -y --no-install-recommends ${CUDA_TOOLKIT_PKG} \
 && rm -rf /var/lib/apt/lists/*

ENV CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:$PATH \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH

# Build and install ttyd (web terminal)
WORKDIR /opt
RUN git clone --depth 1 https://github.com/tsl0922/ttyd.git && \
    cd ttyd && mkdir build && cd build && cmake .. && make -j"$(nproc)" && make install

# ----- everything below runs as non-root appuser -----
# Create appuser only if it doesn't already exist
RUN id -u appuser >/dev/null 2>&1 || useradd -m appuser
USER appuser
WORKDIR /home/appuser

# Python virtualenv for everything (ComfyUI, PyTorch, CopyParty, SageAttention)
RUN python3 -m venv /home/appuser/venv
ENV PATH=/home/appuser/venv/bin:$PATH

# Upgrade pip in venv
RUN pip install --upgrade pip

# Install CopyParty (file manager/uploader) into venv
RUN pip install copyparty

# Install PyTorch CUDA wheels (default cu128 for Blackwell, override via build arg)
ARG PYTORCH_CUDA_CHANNEL="cu128"
ENV PYTORCH_CUDA_CHANNEL=${PYTORCH_CUDA_CHANNEL}
RUN pip install --index-url https://download.pytorch.org/whl/${PYTORCH_CUDA_CHANNEL} \
      torch torchvision torchaudio --extra-index-url https://pypi.org/simple

# Install ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git && \
    pip install -r ComfyUI/requirements.txt

# ComfyUI Manager (optional)
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git ComfyUI/custom_nodes/ComfyUI-Manager || true

# Expose ports
EXPOSE 8188 7681 3923

# Runtime dirs
RUN mkdir -p \
    /home/appuser/ComfyUI/models/checkpoints \
    /home/appuser/ComfyUI/models/loras \
    /home/appuser/ComfyUI/user/default

# Environment knobs
ENV CIVITAI_TOKEN="" \
    LORAS_IDS="" \
    LORAS_CHECKPOINTS="" \
    CHECKPOINT_DIR="/home/appuser/ComfyUI/models/checkpoints" \
    LORA_DIR="/home/appuser/ComfyUI/models/loras" \
    COMFY_EXTRA_ARGS="" \
    USE_SAGEATTN="1" \
    COPY_PARTY_ROOT="/home/appuser" \
    COPY_PARTY_ARGS="--no-dotfiles --nocgi --auth guest::rw"

# Helper scripts
COPY --chown=appuser:appuser downloader.sh /home/appuser/downloader.sh
RUN chmod +x /home/appuser/downloader.sh

COPY --chown=appuser:appuser start.sh /home/appuser/start.sh
RUN chmod +x /home/appuser/start.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/home/appuser/start.sh"]
