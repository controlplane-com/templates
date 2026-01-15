# Example Dockerfile for Strapi
# Copy this to your Strapi project root and customize as needed

# Build stage
FROM node:20-alpine AS build
WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci

# Copy source and build
COPY . .
RUN npm run build

# Production stage
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production

# Copy built application
COPY --from=build /app ./

# Expose Strapi port
EXPOSE 1337

# Start Strapi
CMD ["npm", "run", "start"]
