import process from 'node:process';
import { edgeCases } from './scenarios.mjs';

const app = edgeCases[process.argv[2]]?.app;
if (!app) {
  console.error(`Unknown edge case: ${process.argv[2]}`);
  process.exit(1);
}
console.log(app);
