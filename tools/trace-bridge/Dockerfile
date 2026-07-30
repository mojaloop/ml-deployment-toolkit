FROM node:24-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force
COPY index.js ./
USER node
CMD ["node", "index.js"]
