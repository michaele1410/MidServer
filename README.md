# MidServer
1) Download MID-Server Docker package from Instance
2) Copy to Host
3) Build Image: /home/michael/docker/MidServer# docker build .
4) Watch all images and see MID-Server image is untagged: docker images -a
5) Tag Image: docker tag da024459220c mid-server:latest
6) Go to Docker Stacks and rebuild container