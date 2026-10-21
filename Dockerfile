# dockur/windows with this repo's OEM scripts baked in, so the runner VM can be started from one image.
FROM dockurr/windows:6.05

COPY oem/ /oem/
COPY --chmod=755 entry.sh /run/runner-entry.sh

ENV VERSION="2025" \
    RAM_SIZE="32G" \
    CPU_CORES="12" \
    DISK_SIZE="200G"

ENTRYPOINT ["/usr/bin/tini", "-s", "/run/runner-entry.sh"]
