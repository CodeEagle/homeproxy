'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function loadLuCIModule(relativePath = 'htdocs/luci-static/resources/homeproxyce.js') {
	const source = fs.readFileSync(path.join(__dirname, '..', '..', relativePath), 'utf8');
	const extend = (value) => value;
	const form = {
		DynamicList: { extend }
	};
	const context = {
		baseclass: { extend },
		form,
		_: (value) => value,
		uci: {
			get: () => null,
			set: () => {},
			sections: () => {}
		},
		ui: {
			addNotification: () => {}
		},
		console
	};

	return vm.runInNewContext(`(() => {
		String.prototype.format = function(...args) {
			let index = 0;
			return this.replace(/%[sd]/g, () => String(args[index++]));
		};
		${source}
	})()`, context, { filename: relativePath });
}

module.exports = { loadLuCIModule };
