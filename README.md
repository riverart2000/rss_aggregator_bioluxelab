# RSS Aggregator (BioluxeLab)

Standalone RSS aggregator service extracted from the FlowAgent workspace.

## Included files

- `rss_aggregator.py`: Python HTTP service that merges RSS/Atom/sitemap/Shopify Admin sources
- `rss_feeds.json`: core feed sources and endpoint config (JSON format, supports drip scheduling)
- `deploy_rss_aggregator_prod.sh`: production deploy helper for Ubuntu + systemd
- `rss_reverse_proxy_examples.md`: Nginx/Caddy reverse-proxy examples
- `feed.rss`: latest generated merged feed snapshot

## Requirements

- Python 3.10+
- Outbound network access to configured feed sources

No third-party Python packages are required.

## Local run

```bash
cd /Users/joebains/rss_aggregator_bioluxelab
python3 rss_aggregator.py \
  --feeds-file rss_feeds.json \
  --host 127.0.0.1 \
  --port 18090 \
  --cache-ttl 300 \
  --timeout 20 \
  --max-items 1000 \
  --output-file feed.rss
```

Endpoints:
- `GET /feed.xml` or `/apps/rss` (also `/` and `/feed`): Returns the entire merged feed.
- `GET /publar/rss` (also `/publar/feed` / `/publar/feed.xml`): Returns a timed drip-feed of items.
- `GET /health`: Diagnostic health information.

## Environment variables

See `.env.example` for common settings.

## Production deploy

```bash
cd /Users/joebains/rss_aggregator_bioluxelab
chmod +x deploy_rss_aggregator_prod.sh
./deploy_rss_aggregator_prod.sh
```

Optional overrides can be set via environment variables such as:
- `PROD_SSH_KEY`, `PROD_SSH_HOST`, `PROD_SSH_PORT`
- `RSS_AGG_REMOTE_DIR`, `RSS_AGG_PORT`, `RSS_AGG_MAX_ITEMS`
- `RSS_AGG_CHANNEL_LINK`
- `RSS_AGG_SHOPIFY_DOMAIN`, `RSS_AGG_SHOPIFY_ADMIN_TOKEN`
- `RSS_AGG_SHOPIFY_CLIENT_ID`, `RSS_AGG_SHOPIFY_CLIENT_SECRET`

## Configuration (`rss_feeds.json`)

The config file defines your feed sources and drip-feed schedules. Example:

```json
{
  "feeds": [
    "shopify-admin://all-blogs"
  ],
  "publar": {
    "start_time": "2026-06-06T16:00:00Z",
    "min_interval_hours": 3.0,
    "max_interval_hours": 5.0,
    "initial_count": 1,
    "sort_order": "chronological",
    "channel_title": "Publar Drip Feed",
    "channel_description": "Drip feed starting with 1 blog article, releasing additional articles randomly every 3 to 5 hours."
  }
}
```

Drip-feed Options:
- `start_time`: Reference ISO-8601 timestamp. The scheduling is deterministic, and state is preserved on restart using `publar_state.json`.
- `min_interval_hours`: Minimum randomized hours before releasing each additional blog article.
- `max_interval_hours`: Maximum randomized hours before releasing each additional blog article.
- `initial_count`: Number of blog articles to show right from the start time.
- `sort_order`: Order of article release from the pool. Supports `"chronological"` (oldest first) or `"reverse-chronological"` (newest first).
- `channel_title`: Custom feed title for the `/publar/rss` endpoint.
- `channel_description`: Custom feed description.

## Persistence State

The application persists sequence progression in `publar_state.json`, which tracks the count floor across application restarts, protecting deterministic pacing from timing rollback or clock drifts.

## Notes

- Keep the aggregator bound to loopback (`127.0.0.1`) behind your reverse proxy.
- Use `shopify-admin://all-blogs` in `rss_feeds.json` for full Shopify Admin coverage.
