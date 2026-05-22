# Image Variants Quick Reference

This document provides a quick reference to the different base image variants available in this project. Each variant is built from a specific set of components to serve different use cases.

## certs

*   **Description**: CA certs only
*   **Components**:
    *   `setup_system_config_files`
    *   `install_ca_certs`
    *   `install_tzdb`

## minimal

*   **Description**: Minimal rootfs with glibc and busybox
*   **Components**:
    *   `setup_system_config_files`
    *   `install_glibc`
    *   `install_busybox`
    *   `install_ca_certs`
    *   `install_tzdb`
    *   `configure_system`

## base

*   **Description**: Base rootfs with glibc, busybox, bash, and ncurses
*   **Components**:
    *   `setup_system_config_files`
    *   `install_glibc`
    *   `install_ncurses`
    *   `install_busybox`
    *   `install_bash`
    *   `install_ca_certs`
    *   `install_tzdb`
    *   `configure_system`

## jdk

*   **Description**: jdk rootfs with JDK, tini, and all base components
*   **Components**:
    *   `setup_system_config_files`
    *   `install_glibc`
    *   `install_ncurses`
    *   `install_busybox`
    *   `install_bash`
    *   `install_ca_certs`
    *   `install_tzdb`
    *   `install_tini`
    *   `install_jdk`
    *   `configure_system`

## node

*   **Description**: Node.js rootfs with Node.js, tini, and all base components
*   **Components**:
    *   `setup_system_config_files`
    *   `install_glibc`
    *   `install_libstdc++`
    *   `install_ncurses`
    *   `install_busybox`
    *   `install_bash`
    *   `install_ca_certs`
    *   `install_tzdb`
    *   `install_tini`
    *   `install_node`
    *   `configure_system`

## full

*   **Description**: Development rootfs with full busybox tools and all components
*   **Components**:
    *   `setup_system_config_files`
    *   `install_glibc`
    *   `install_ncurses`
    *   `install_busybox`
    *   `install_libstdc++`
    *   `install_bash`
    *   `install_ca_certs`
    *   `install_tzdb`
    *   `install_tini`
