/** @type {import('next').NextConfig} */
const internalApiUrl = process.env.INTERNAL_API_URL || process.env.BACKEND_URL || "http://127.0.0.1:8000";
const cleanInternalApiUrl = internalApiUrl.replace(/\/api\/?$/, "").replace(/\/$/, "");

const nextConfig = {
  reactStrictMode: true,
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `${cleanInternalApiUrl}/api/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;

