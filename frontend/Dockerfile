# Stage 1: Build the Flutter web app
FROM debian:latest AS build-env

# Declare the build argument that Railway will pass in from your Variables tab
ARG SERVER_BASE_URL

# Install system dependencies required by Flutter
RUN apt-get update && apt-get install -y curl git wget unzip gdb libstdc++6 libglu1-mesa fonts-droid-fallback lib32stdc++6 python3
RUN apt-get clean

# Clone the Flutter SDK (stable channel)
RUN git clone https://github.com/flutter/flutter.git /usr/local/flutter
ENV PATH="/usr/local/flutter/bin:/usr/local/flutter/bin/cache/dart-sdk/bin:${PATH}"

RUN flutter config --enable-web

# Copy your frontend app source code into the container
COPY . /app
WORKDIR /app

# Build the web app, baking in your backend URL from the environment variable
RUN flutter build web --release --dart-define=SERVER_BASE_URL=$SERVER_BASE_URL

# Stage 2: Serve the compiled app using Nginx
FROM nginx:alpine
COPY --from=build-env /app/build/web /usr/share/nginx/html
EXPOSE 80