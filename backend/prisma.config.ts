import 'dotenv/config';
import path from 'node:path';
import { defineConfig } from 'prisma/config';

// Replaces the deprecated `prisma` key in package.json. Note that with a config
// file present Prisma no longer auto-loads .env, hence the import above.
export default defineConfig({
  schema: path.join('prisma', 'schema.prisma'),
  migrations: {
    seed: 'tsx prisma/seed.ts',
  },
});
