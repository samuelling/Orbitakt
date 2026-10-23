'use strict';
// node web/build.js  ->  docs/play/index.html (one self-contained file)
const fs = require('fs'), path = require('path');
const read = f => fs.readFileSync(path.join(__dirname, 'src', f), 'utf8');

const bundle = ['sgp4.js', 'catalog.js', 'plate.js', 'model.js', 'engine.js', 'ui.js'].map(f => '/* ' + f + ' */\n' + read(f)).join('\n');
const worklet = read('dsp.js') + '\n' + read('worklet.js');
if (/<\/script/i.test(bundle + worklet)) throw new Error('"</script" inside the sources');

let html = read('template.html');
// function replacers: the sources contain "$" sequences that String.replace would otherwise expand
html = html.replace('/*WORKLET*/', () => worklet).replace('/*BUNDLE*/', () => bundle);
fs.mkdirSync(path.join(__dirname, '..', 'docs', 'play'), { recursive: true });
fs.writeFileSync(path.join(__dirname, '..', 'docs', 'play', 'index.html'), html);
console.log('docs/play/index.html', (html.length / 1024).toFixed(0) + ' KB');
