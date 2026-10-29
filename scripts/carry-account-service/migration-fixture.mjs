import { readFile, readdir } from 'node:fs/promises';

// PGlite executes every data/auth migration. These provider infrastructure
// migrations require pg_cron/pg_net/Vault and are verified on hosted PostgreSQL;
// explicitly list them rather than silently skipping unsupported SQL/errors.
const hostedOnly=new Set(['install_asset_cleanup_scheduler','restrict_cleanup_transport','account_private_asset_bucket','install_account_maintenance_scheduler']);
export async function applyPortableMigrations(database) {
  const directory=new URL('./supabase/migrations/',import.meta.url);
  for(const name of (await readdir(directory)).filter(n=>n.endsWith('.sql')).sort()) {
    const sql=await readFile(new URL(name,directory),'utf8');
    const label=name.replace(/^\d+_/,'').replace(/\.sql$/,'');
    const marked=sql.startsWith('-- carry-test-runtime: hosted-only\n');
    if(marked!==hostedOnly.has(label))throw new Error('migration_runtime_marker_mismatch');
    if(!marked)await database.exec(sql);
  }
}
