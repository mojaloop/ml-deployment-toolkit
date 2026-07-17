FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
COPY index.js ./
USER node
CMD ["node", "index.js"]
