import { bundle } from 'luabundle';
import { promises as fs } from 'fs';
import path from 'path';

async function main() {
	const workspaceRoot = process.cwd();
	const simtestDir = path.resolve(workspaceRoot, 'simtest');
	const entryFile = path.resolve(simtestDir, 'Main.lua');
	const buildDir = path.resolve(simtestDir, 'build');
	
	const luaPaths = [
		path.join(simtestDir, '?.lua'),
		path.join(simtestDir, '?', 'init.lua'),
		path.join(workspaceRoot, '?.lua'),
		path.join(workspaceRoot, '?', 'init.lua'),
	];

	await fs.mkdir(buildDir, { recursive: true });

	const bundledLua = bundle(entryFile, {
		metadata: false,
		paths: luaPaths,
		expressionHandler: (module, expression) => {
			if (expression?.loc?.start) {
				const start = expression.loc.start;
				console.warn(
					`WARNING: Non-literal require found in '${module.name}' at ${start.line}:${start.column}`,
				);
			} else {
				console.warn(`WARNING: Non-literal require found in '${module.name}' at unknown location`);
			}
		},
	});

	const outputPath = path.join(buildDir, 'simtest.lua');
	await fs.writeFile(outputPath, bundledLua, 'utf8');
	console.log(`SimTest bundle created as ${outputPath}`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
