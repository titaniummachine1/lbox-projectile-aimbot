import { bundle } from 'luabundle';
import { promises as fs } from 'fs';
import path from 'path';

async function main() {
	const workspaceRoot = process.cwd();
	const entryFile = path.resolve(workspaceRoot, 'src', 'main.lua');
	const buildDir = path.resolve(
		process.env.BUNDLE_OUTPUT_DIR ? path.resolve(process.env.BUNDLE_OUTPUT_DIR) : path.join(workspaceRoot, 'build'),
	);
	const titleFile = path.resolve(workspaceRoot, 'title.txt');
	const luaPaths = [
		path.join(workspaceRoot, 'src', '?.lua'),
		path.join(workspaceRoot, 'src', '?', 'init.lua'),
		path.join(workspaceRoot, '?.lua'),
		path.join(workspaceRoot, '?', 'init.lua'),
	];

	let outputName = 'projaimbot.lua';
	try {
		const titleContents = (await fs.readFile(titleFile, 'utf8')).trim();
		if (titleContents.length > 0) {
			outputName = titleContents;
		}
	} catch (_) {
		// title.txt missing is fine; fall back to default name
	}

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

	const outputPath = path.join(buildDir, outputName);
	await fs.writeFile(outputPath, bundledLua, 'utf8');
	console.log(`Library bundle created as ${outputPath}`);

	// Prototypes are deployed as individual files, not bundled
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});