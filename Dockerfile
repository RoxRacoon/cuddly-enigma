# ComfyUI + SageAttention + cu128 PyTorch + ttyd + CopyParty
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    UV_LOCALE=C.UTF-8 \
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

# Make `python` and `pip` point to Python 3
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 1 && \
    update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 1

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
RUN python -m venv /home/appuser/venv
ENV PATH=/home/appuser/venv/bin:$PATH

# Upgrade pip in venv
RUN pip install --upgrade pip

# Install CopyParty (file manager/uploader) into venv
RUN pip install --no-cache-dir copyparty

# Install PyTorch with CUDA 12.8 wheels (Blackwell-ready)
RUN pip install --index-url https://download.pytorch.org/whl/cu128 \
      torch torchvision torchaudio --extra-index-url https://pypi.org/simple

# Install ComfyUI
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git && \
    pip install --no-cache-dir -r ComfyUI/requirements.txt

# ComfyUI Manager (optional)
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git ComfyUI/custom_nodes/ComfyUI-Manager || true

# Expose ports
EXPOSE 8188 7681 3923

# Runtime dirs
RUN mkdir -p /home/appuser/models/checkpoints /home/appuser/models/loras /home/appuser/ComfyUI/user/default

# Environment knobs
ENV CIVITAI_TOKEN="" \
    LORAS_IDS="" \
    LORAS_CHECKPOINTS="" \
    CHECKPOINT_DIR="/home/appuser/models/checkpoints" \
    LORA_DIR="/home/appuser/models/loras" \
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
