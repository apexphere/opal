# PostgreSQL HOT updates

When PostgreSQL updates a row whose new version fits on the same heap page
and no indexed columns change, it performs a Heap-Only Tuple (HOT) update.
HOT updates skip index maintenance, dramatically reducing write amplification
and bloat for hot tables.

Triggers:
- New tuple fits on same page (controlled by `fillfactor`).
- No indexed columns are modified.
- No `INSERT ... ON CONFLICT` redirects.

Setting `fillfactor=80` on a heavily-updated table reserves space so HOT can
fire more often.
