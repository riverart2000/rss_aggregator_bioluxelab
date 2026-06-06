Reverse proxy examples for the RSS aggregator

Service assumptions:
- RSS aggregator listens on origin loopback: http://127.0.0.1:18090/feed.xml
- Primary public path: /apps/rss
- Optional legacy alias: /feeds/aggregated.xml

Nginx example (primary path)

location = /apps/rss {
    proxy_pass http://127.0.0.1:18090/feed.xml;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 30s;
    add_header Content-Type application/rss+xml always;
}

Nginx compatibility for Shopify app proxy root requests

location = / {
    if ($args ~* "(^|&)path_prefix=(%2[Ff]|/)apps(%2[Ff]|/)rss(&|$)") {
        rewrite ^ /apps/rss last;
    }

    proxy_pass http://127.0.0.1:3000;
}

Caddy example (primary plus legacy alias)

@rss path /apps/rss /feeds/aggregated.xml
handle @rss {
    rewrite * /feed.xml
    reverse_proxy 127.0.0.1:18090
}

Notes for Cloudflare

- Keep aggregator bound to 127.0.0.1 so it is only reachable through your web server.
- Cloudflare remains the edge; no special Cloudflare code is required in the Python app.
- If a platform strips custom ports, ensure /apps/rss is available on standard 443.
- See ops/production/README.md for the current production baseline and mirrored configs.
