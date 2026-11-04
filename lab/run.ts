/**
 * Runs the demography lab over many seeds and checks the calibration targets.
 * Usage: npx tsx lab/run.ts [seeds=20] [years=300] [K]
 */
import { buildLifeTable, lifeExpectancy } from "../src/shared/demography";
import { runLab } from "./sim";

const seeds = Number(process.argv[2] ?? 20);
const years = Number(process.argv[3] ?? 300);
const K = process.argv[4] ? Number(process.argv[4]) : undefined;

const cdf = buildLifeTable();
const e0 = lifeExpectancy(cdf);
console.log(`life table: e0=${e0.toFixed(2)}  die<5=${(cdf[60] * 100).toFixed(2)}%  alive@80=${((1 - cdf[960]) * 100).toFixed(1)}%  alive@90=${((1 - cdf[1080]) * 100).toFixed(2)}%  alive@100=${((1 - cdf[1200]) * 100).toFixed(3)}%`);

const t0 = Date.now();
const results = Array.from({ length: seeds }, (_, i) => runLab(1000 + i, years, K));
for (const r of results) {
  console.log(`seed ${r.seed}: final=${r.finalPop} peak=${r.peakPop} births=${r.births} cohortE0=${r.cohortE0.toFixed(1)} u5=${(r.under5Share * 100).toFixed(1)}% maxAge=${r.maxFateAge.toFixed(1)} kin=${r.kinViolations} decades=[${r.popByDecade.join(",")}]`);
}
const survived = results.filter((r) => !r.extinct).length;
const kin = results.reduce((a, r) => a + r.kinViolations, 0);
const avgFinal = results.reduce((a, r) => a + r.finalPop, 0) / results.length;
console.log(`\nsurvived ${survived}/${seeds}, kin violations ${kin}, mean final pop ${avgFinal.toFixed(0)} (K=${results[0].K}, ratio ${(avgFinal / results[0].K).toFixed(2)}), ${Date.now() - t0} ms`);

const checks: [string, boolean][] = [
  ["e0 in [58,62]", e0 >= 58 && e0 <= 62],
  ["under-5 deaths 2–4%", cdf[60] >= 0.02 && cdf[60] <= 0.04],
  ["alive at 100 < 0.5%", 1 - cdf[1200] < 0.005],
  ["max fate age ≤ 110", results.every((r) => r.maxFateAge <= 110)],
  [`≥ 95% seeds survive`, survived >= Math.ceil(seeds * 0.95)],
  ["zero kin violations", kin === 0],
];
let ok = true;
for (const [name, pass] of checks) {
  console.log(`${pass ? "PASS" : "FAIL"}  ${name}`);
  ok &&= pass;
}
process.exit(ok ? 0 : 1);
