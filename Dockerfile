
# ########################################################################################################################
# 1st Stage:
#     - Download the MID installation ZIP file, verify the digital signature and unzip the ZIP file to the base directory
#     - Copy the required scripts and other files from the recipe asset folder to the base directory
#     - Set the group's file permissions to match the owner's file permissions for the entire base directory
# ########################################################################################################################

FROM eclipse-temurin:8-jdk AS pre_installation

RUN apt-get update -y && \
    apt-get install -y bash wget unzip && \
    rm -rf /var/lib/apt/lists/*

ARG MID_INSTALLATION_URL=https://install.service-now.com/glide/distribution/builds/package/app-signed/mid/2025/10/12/mid.zurich-07-01-2025__patch2-09-24-2025_10-12-2025_0904.linux.x86-64.zip
ARG MID_INSTALLATION_FILE=""
ARG MID_SIGNATURE_VERIFICATION="TRUE"

WORKDIR /opt/snc_mid_server/

COPY asset/* /opt/snc_mid_server/

# download.sh and validate_signature.sh
RUN chmod 750 /opt/snc_mid_server/*.sh

RUN echo "Check MID installer URL: ${MID_INSTALLATION_URL} or Local installer: ${MID_INSTALLATION_FILE}"

# Download the installation ZIP file or use the local one
RUN if [ -z "$MID_INSTALLATION_FILE" ] ; \
    then /opt/snc_mid_server/download.sh "$MID_INSTALLATION_URL" ; \
    else echo "Use local file: $MID_INSTALLATION_FILE" && ls -alF /opt/snc_mid_server/ && mv "/opt/snc_mid_server/$MID_INSTALLATION_FILE" /tmp/mid.zip ; fi

# Verify mid.zip signature
RUN if [ "$MID_SIGNATURE_VERIFICATION" = "TRUE" ] || [ "$MID_SIGNATURE_VERIFICATION" = "true" ] ; \
    then echo "Verify the signature of the installation file" && /opt/snc_mid_server/validate_signature.sh /tmp/mid.zip ; \
    else echo "Skip signature validation of the installation file" ; fi

# Clean up and extract mid installation zip file to /opt/snc_mid_server/
RUN rm /opt/snc_mid_server/* && unzip -d /opt/snc_mid_server/ /tmp/mid.zip && rm -f /tmp/mid.zip

# Copy only required scripts and .container
COPY asset/init asset/.container asset/check_health.sh asset/post_start.sh asset/pre_stop.sh asset/calculate_mid_env_hash.sh /opt/snc_mid_server/


# Install ARM64 Tanuki Wrapper and patch wrapper.conf
RUN WRAPPER_URL="https://download.tanukisoftware.com/wrapper/3.5.51/wrapper-linux-arm-64-3.5.51.tar.gz" && \
    echo "Downloading ARM64 wrapper from $WRAPPER_URL" && \
    wget -q -O /tmp/wrapper.tar.gz "$WRAPPER_URL" && \
    mkdir -p /tmp/wrapper && \
    tar -xzf /tmp/wrapper.tar.gz -C /tmp/wrapper --strip-components=1 && \
    \
    # Ensure expected MID directories exist (under agent/)
    mkdir -p /opt/snc_mid_server/agent/bin && \
    mkdir -p /opt/snc_mid_server/agent/lib && \
    \
    # Copy and rename wrapper binary into the location mid.sh expects
    cp /tmp/wrapper/bin/wrapper /opt/snc_mid_server/agent/bin/wrapper-linux-arm-64 && \
    chmod 755 /opt/snc_mid_server/agent/bin/wrapper-linux-arm-64 && \
    \
    # Copy and rename shared library into the expected agent/lib path
    cp /tmp/wrapper/lib/libwrapper.so /opt/snc_mid_server/agent/lib/libwrapper-linux-arm-64.so && \
    chmod 755 /opt/snc_mid_server/agent/lib/libwrapper-linux-arm-64.so && \
    \
    # Patch wrapper.conf to use ARM64 names (paths bleiben relativ zu agent/)
    sed -i 's/wrapper-linux-x86-64/wrapper-linux-arm-64/g' /opt/snc_mid_server/agent/conf/wrapper.conf && \
    sed -i 's/libwrapper-linux-x86-64/libwrapper-linux-arm-64/g' /opt/snc_mid_server/agent/conf/wrapper.conf && \
    \
    # Cleanup
    rm -rf /tmp/wrapper /tmp/wrapper.tar.gz

# Configure the MID Server to use the system Java installation
RUN sed -i 's|^wrapper.java.command=.*|wrapper.java.command=/usr/bin/java|' \
    /opt/snc_mid_server/agent/conf/wrapper.conf

RUN mkdir -p /opt/snc_mid_server/mid_container && \
    /usr/bin/chmod 2775 /opt/snc_mid_server/mid_container
    
# Running this command in this stage reduces the final image size.
RUN chmod -R g=u /opt/snc_mid_server

# ########################################################################################################################
# Final Stage:
#     - Install the base OS security and bugfix updates
#     - Install the packages required by the MID Server application
#     - Add the mid user and group
#     - Copy application files from the previous stage
#     - Grant the execution permission for the scripts and binaries that do not have it
# ########################################################################################################################

FROM almalinux:9.2

# Install security and bugfix updates, and then the required packages.
RUN dnf update -y --security --bugfix && \
    dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    dnf install -y --allowerasing glibc-langpack-en \
                    bind-utils \
                    xmlstarlet \
                    curl \
                    procps-ng \
                    diffutils \
                    net-tools && \
                    java-1.8.0-openjdk-headless && \
    dnf clean all -y && \
    rm -rf /tmp/*

ARG MID_USERNAME=mid
ARG GROUP_ID=1001
ARG USER_ID=1001

# Env Variables
ENV MID_INSTANCE_URL="" \
    MID_INSTANCE_USERNAME="" \
    MID_INSTANCE_PASSWORD="" \
    MID_SERVER_NAME="" \
    # Ensure UTF-8 Encoding
    LANG="en_US.UTF-8" \
    # Optional Env Var
    MID_PROXY_HOST="" \
    MID_PROXY_PORT="" \
    MID_PROXY_USERNAME="" \
    MID_PROXY_PASSWORD="" \
    MID_SECRETS_FILE="" \
    MID_MUTUAL_AUTH_PEM_FILE="" \
    MID_SSL_BOOTSTRAP_CERT_REVOCATION_CHECK="" \
    MID_SSL_USE_INSTANCE_SECURITY_POLICY="" \
    # Optional: encourage group-write on runtime-created files
    UMASK="0002"

# Add the mid user and group
RUN if [[ -z "${GROUP_ID}" ]]; then GROUP_ID=1001; fi && \
    if [[ -z "${USER_ID}" ]]; then USER_ID=1001; fi && \
    echo "Add GROUP id: ${GROUP_ID}, USER id: ${USER_ID} for username: ${MID_USERNAME}" && \
    groupadd -g "$GROUP_ID" "$MID_USERNAME" && \
    useradd -c "MID container user" --shell /sbin/nologin -r -m -u "$USER_ID" -g "$MID_USERNAME" "$MID_USERNAME"

# Copy files from previous stage and make them owned by the mid user and the root group.
COPY --chown=$USER_ID:0 --from=pre_installation /opt/snc_mid_server /opt/snc_mid_server

# Ensure runtime dirs exist and set ownership/permissions (OpenShift/rootless friendly)
# - Directories: 2775 (rwx for owner/group, setgid so new files keep group=0)
# - Files in logs (if any): 664
# - Pre-create agent0.log.0 owned by 'mid' so init's 'touch' succeeds
RUN mkdir -p /opt/snc_mid_server/agent/logs && \
    mkdir -p /opt/snc_mid_server/agent/work && \
    mkdir -p /opt/snc_mid_server/agent/tmp && \
    /usr/bin/chown -R "$USER_ID":0 /opt/snc_mid_server && \
    find /opt/snc_mid_server/agent -type d -exec /usr/bin/chmod 2775 {} \; && \
    find /opt/snc_mid_server/agent/logs -type f -exec /usr/bin/chmod 664 {} \; || true && \
    touch /opt/snc_mid_server/agent/logs/agent0.log.0 && \
    /usr/bin/chown "$USER_ID":0 /opt/snc_mid_server/agent/logs/agent0.log.0 && \
    /usr/bin/chmod 664 /opt/snc_mid_server/agent/logs/agent0.log.0

# When containers run as the root user, file permissions are ignored, but for rootless containers,
# the permission bit is required in order to execute files.
RUN /usr/bin/chmod 775 /opt/snc_mid_server && \
    /usr/bin/chmod 775 /opt/snc_mid_server/init && \
    /usr/bin/chmod 775 /opt/snc_mid_server/*.sh && \
    /usr/bin/chmod 775 /opt/snc_mid_server/agent/bin/wrapper-linux*

# Check if the wrapper PID file exists and a HeartBeat is processed in the last 30 minutes
HEALTHCHECK --interval=5m --start-period=3m --retries=3 --timeout=15s \
    CMD /opt/snc_mid_server/check_health.sh || exit 1

WORKDIR /opt/snc_mid_server/

USER $MID_USERNAME

# If your init script supports UMASK, export it before start (non-breaking otherwise)
ENTRYPOINT ["/opt/snc_mid_server/init", "start"]
