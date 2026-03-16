FROM ubuntu:24.04

ARG USERNAME=dev

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    sudo \
    zsh \
    ca-certificates \
    openssh-client \
    rsync \
    neovim \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS) for Claude Code
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install OpenCode
RUN curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path \
    && cp /root/.opencode/bin/opencode /usr/local/bin/opencode

# Install eza
RUN curl -sSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | gpg --dearmor -o /usr/share/keyrings/eza.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/eza.gpg] http://deb.gierens.de stable main" > /etc/apt/sources.list.d/eza.list \
    && apt-get update && apt-get install -y eza \
    && rm -rf /var/lib/apt/lists/*

# Install oh-my-zsh system-wide so every runtime-created user can use it
ENV ZSH=/opt/oh-my-zsh
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended \
    && chmod -R 755 /opt/oh-my-zsh

# Copy user setup script
COPY scripts/setup-user.sh /usr/local/bin/setup-user.sh
RUN chmod +x /usr/local/bin/setup-user.sh

# Create mount points and workspace
RUN mkdir -p /workspace /opt/host-ssh /opt/git-auth /opt/claude-auth /opt/opencode-auth

CMD ["sleep", "infinity"]
