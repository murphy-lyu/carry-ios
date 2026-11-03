import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createDatabasePool } from "./database-pool.mjs";

test("idle network errors are absorbed without exposing provider details; pool connection and query waits are bounded", () => {
  let settings,
    called = 0;
  class Pool extends EventEmitter {
    constructor(options) {
      super();
      settings = options;
    }
  }
  const pool = createDatabasePool({ Pool }, "synthetic-local", {
    onIdleError: () => {
      called++;
      throw Error("logger failed");
    },
  });
  assert.doesNotThrow(() =>
    pool.emit("error", Error("private database host and password")),
  );
  assert.equal(called, 1);
  assert.ok(
    settings.connectionTimeoutMillis > 0 &&
      settings.connectionTimeoutMillis <= 5000,
  );
  assert.ok(settings.query_timeout > 15000 && settings.query_timeout <= 20000);
  assert.equal(settings.ssl.rejectUnauthorized, true);
  assert.equal(settings.max, 2);
});

test("a real TCP endpoint that never completes PostgreSQL handshake yields retryable 503 within the pool deadline", async () => {
  const { createServer } = await import("node:net"),
    { default: pg } = await import("pg");
  const { postgresDriver } = await import("./postgres-driver.mjs"),
    { postgresStore } = await import("./postgres-store.mjs");
  const sockets = new Set(),
    server = createServer((socket) => {
      sockets.add(socket);
      socket.on("close", () => sockets.delete(socket));
    });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const pool = createDatabasePool(
    pg,
    `postgresql://synthetic@127.0.0.1:${server.address().port}/synthetic`,
    { onIdleError: () => {} },
  );
  const core = Object.fromEntries(
    [
      "assertOwner",
      "assertAccount",
      "ownsTrips",
      "readGraph",
      "execute",
      "prepareUndo",
    ].map((k) => [k, async () => {}]),
  );
  const store = postgresStore({ driver: postgresDriver(pool), core }),
    start = Date.now();
  try {
    await assert.rejects(
      store.getClient({ id: "synthetic" }),
      (e) => e.code === "store_unavailable" && e.status === 503,
    );
    assert.ok(Date.now() - start < 8000);
  } finally {
    for (const socket of sockets) socket.destroy();
    await pool.end();
    await new Promise((r) => server.close(r));
  }
});
