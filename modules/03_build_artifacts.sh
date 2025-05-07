#!/bin/bash
# MODULE 3: Create dummy Unity files
set -euo pipefail
source "/root/base/lib/env.sh"

UNITY_DIR="$DARKSITE_DIR/opt/unityserver"

log "[*] [Module 3] Building dummy Unity server assets..."
rm -rf "$UNITY_DIR"
mkdir -p "$UNITY_DIR/Data" "$UNITY_DIR/Scenes" "$UNITY_DIR/Scripts"

echo "Dummy Asset Data" > "$UNITY_DIR/Data/readme.txt"
echo "Dummy Scene Data" > "$UNITY_DIR/Scenes/sample_scene.unity"
echo "Dummy Script Content" > "$UNITY_DIR/Scripts/sample_script.cs"

cat > "$UNITY_DIR/server.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#define PORT 7777
int main() {
    int server_fd, new_socket;
    struct sockaddr_in address;
    int addrlen = sizeof(address);
    printf("[INFO] Starting Unity Dummy Server on port %d...\n", PORT);
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd == 0) { perror("[ERROR] Socket failed"); exit(EXIT_FAILURE); }
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(PORT);
    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("[ERROR] Bind failed"); exit(EXIT_FAILURE);
    }
    if (listen(server_fd, 10) < 0) {
        perror("[ERROR] Listen failed"); exit(EXIT_FAILURE);
    }
    printf("[INFO] Unity Dummy Server ready. Waiting for players...\n");
    while (1) {
        new_socket = accept(server_fd, (struct sockaddr *)&address, (socklen_t*)&addrlen);
        if (new_socket >= 0) {
            printf("[INFO] Player connected: %s:%d\n", inet_ntoa(address.sin_addr), ntohs(address.sin_port));
            send(new_socket, "Welcome to Dummy Unity Server!\n", 30, 0);
            close(new_socket);
        }
    }
}
EOF

gcc "$UNITY_DIR/server.c" -o "$UNITY_DIR/server.x86_64" -static
rm "$UNITY_DIR/server.c"
chmod +x "$UNITY_DIR/server.x86_64"
