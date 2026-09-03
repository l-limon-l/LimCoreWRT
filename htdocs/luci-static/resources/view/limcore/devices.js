/* SPDX-License-Identifier: GPL-2.0-only
 *
 * Device Control — list every device the router knows about, give it a name of
 * your own, and cut or restore its internet access with one click.
 *
 * Ported into LimCore from Device-Control (luci-app-netpause) by Yany1944:
 * https://github.com/Yany1944/Device-Control
 * The backend now answers on luci.limcore instead of luci.netpause; the page
 * itself is otherwise the original.
 */

'use strict';
'require view';
'require rpc';
'require ui';
'require poll';
'require dom';

var callDevices = rpc.declare({
	object: 'luci.limcore',
	method: 'devices',
	expect: { devices: [] }
});

var callSetPaused = rpc.declare({
	object: 'luci.limcore',
	method: 'set_paused',
	params: [ 'mac', 'paused' ],
	expect: { }
});

var callSetInfo = rpc.declare({
	object: 'luci.limcore',
	method: 'set_info',
	params: [ 'mac', 'label', 'note' ],
	expect: { }
});

var callResumeAll = rpc.declare({
	object: 'luci.limcore',
	method: 'resume_all',
	expect: { }
});

/* Layout is a CSS grid declared here rather than LuCI's .table/.th/.td classes.
   Those classes only line up when the active theme implements them as a CSS
   table, and themes built on utility CSS frequently do not — the header cells
   then fall back to block layout and stack on top of each other while the body
   rows still look fine. Owning the grid keeps the header and the rows on
   identical columns under any theme. */
var GRID_COLUMNS = 'minmax(0,2.4fr) minmax(0,1.2fr) minmax(0,0.9fr) minmax(0,1fr) minmax(0,1.6fr)';

function gridStyle(extra) {
	return 'display:grid;grid-template-columns:' + GRID_COLUMNS +
	       ';gap:.75rem;align-items:center;' + (extra || '');
}

return view.extend({
	/* Guards the poll: a refresh landing mid-click would rebuild the table under
	   the button being pressed, and an open dialog would lose what was typed. */
	busy: false,

	load: function() {
		return callDevices();
	},

	renderHeader: function() {
		var titles = [ _('Device'), _('IP address'), _('Status'), _('Internet'), _('Action') ];

		return E('div', {
			'style': gridStyle('font-weight:600;padding:0 .25rem .5rem;' +
			                   'border-bottom:1px solid rgba(128,128,128,.35)')
		}, titles.map(function(title, i) {
			return E('div', {
				'style': (i === titles.length - 1) ? 'text-align:right' : ''
			}, title);
		}));
	},

	renderRows: function(devices) {
		var rows = [];

		for (var i = 0; i < devices.length; i++) {
			var dev = devices[i];

			/* The name the router itself saw stays in view once a custom label
			   hides it — otherwise a renamed device is hard to match against the
			   DHCP list. Anything already used as the title is left out, so a
			   device with no name at all does not print its MAC twice. */
			var parts = [];
			if (dev.hostname && dev.hostname != dev.display)
				parts.push(dev.hostname);
			if (dev.mac != dev.display)
				parts.push(dev.mac);
			if (dev.randomised && !dev.hostname)
				parts.push(_('randomised MAC'));

			var secondary = parts.join(' · ');

			var title = [ E('strong', {}, dev.display) ];
			if (dev.note)
				title.push(E('span', { 'style': 'opacity:.7' }, ' (' + dev.note + ')'));

			var presence = dev.online
				? E('span', { 'class': 'label' }, _('Online'))
				: E('span', { 'style': 'opacity:.6' }, _('Offline'));

			var access = dev.paused
				? E('span', { 'style': 'color:#c00;font-weight:bold' }, _('Paused'))
				: E('span', { 'style': 'color:#0a0' }, _('Allowed'));

			rows.push(E('div', {
				'style': gridStyle('padding:.55rem .25rem;' +
				                   'border-bottom:1px solid rgba(128,128,128,.15)')
			}, [
				E('div', { 'style': 'min-width:0' }, [
					E('div', { 'style': 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap' }, title),
					E('small', { 'style': 'opacity:.6' }, secondary)
				]),
				E('div', {}, dev.ip || '-'),
				E('div', {}, presence),
				E('div', {}, access),
				E('div', { 'style': 'text-align:right;white-space:nowrap' }, [
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'click': ui.createHandlerFn(this, 'handleEdit', dev)
					}, _('Rename')),
					' ',
					E('button', {
						'class': dev.paused ? 'cbi-button cbi-button-positive' : 'cbi-button cbi-button-negative',
						'click': ui.createHandlerFn(this, 'handleToggle', dev)
					}, dev.paused ? _('Resume') : _('Pause'))
				])
			]));
		}

		if (!rows.length)
			rows.push(E('div', { 'style': 'padding:1rem .25rem;text-align:center;opacity:.6' },
				E('em', {}, _('No devices seen yet.'))));

		return rows;
	},

	/* Header and body are rebuilt together: both are grid rows sharing one column
	   template, so they can never drift apart. */
	redraw: function(devices) {
		var table = document.getElementById('limcore-devices-table');
		if (table)
			dom.content(table, [ this.renderHeader() ].concat(this.renderRows(devices)));

		var resumeAll = document.getElementById('limcore-devices-resume-all');
		if (resumeAll)
			resumeAll.style.display = devices.some(function(d) { return d.paused; }) ? '' : 'none';
	},

	refresh: function() {
		if (this.busy)
			return Promise.resolve();

		var self = this;
		return callDevices().then(function(devices) { self.redraw(devices); });
	},

	handleEdit: function(dev) {
		var labelInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%',
			'maxlength': '48',
			'value': dev.label || '',
			'placeholder': dev.hostname || dev.mac
		});

		var noteInput = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:100%',
			'maxlength': '64',
			'value': dev.note || '',
			'placeholder': _('account, owner, specs…')
		});

		/* Held while the dialog is up, so the ten-second poll cannot redraw the
		   table and discard what is being typed. */
		this.busy = true;

		ui.showModal(_('Rename device'), [
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Display name')),
				E('div', { 'class': 'cbi-value-field' }, [
					labelInput,
					E('div', { 'class': 'cbi-value-description' },
						_('Leave empty to fall back to the name the router sees.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Note')),
				E('div', { 'class': 'cbi-value-field' }, [
					noteInput,
					E('div', { 'class': 'cbi-value-description' },
						_('Shown in brackets after the name — an account, an owner, a spec.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('MAC address')),
				E('div', { 'class': 'cbi-value-field' }, E('code', {}, dev.mac))
			]),
			E('div', { 'class': 'right' }, [
				E('button', {
					'class': 'btn cbi-button-neutral',
					'click': ui.createHandlerFn(this, 'handleEditCancel')
				}, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleEditSave', dev, labelInput, noteInput)
				}, _('Save'))
			])
		]);

		labelInput.focus();
		return Promise.resolve();
	},

	handleEditCancel: function() {
		this.busy = false;
		ui.hideModal();
		return Promise.resolve();
	},

	handleEditSave: function(dev, labelInput, noteInput) {
		var self = this;

		return callSetInfo(dev.mac, labelInput.value || '', noteInput.value || '').then(function(res) {
			if (res && res.success === false)
				ui.addNotification(null,
					E('p', {}, _('Could not save: %s').format(res.error || _('unknown error'))), 'error');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Request failed: %s').format(err.message)), 'error');
		}).finally(function() {
			self.busy = false;
			ui.hideModal();
			return self.refresh();
		});
	},

	handleToggle: function(dev) {
		var self = this;
		this.busy = true;

		return callSetPaused(dev.mac, !dev.paused).then(function(res) {
			if (res && res.success === false)
				ui.addNotification(null,
					E('p', {}, _('Could not change %s: %s').format(dev.display, res.error || _('unknown error'))),
					'error');
			else
				ui.addNotification(null,
					E('p', {}, dev.paused
						? _('Internet restored for %s.').format(dev.display)
						: _('Internet paused for %s.').format(dev.display)),
					'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Request failed: %s').format(err.message)), 'error');
		}).finally(function() {
			self.busy = false;
			return self.refresh();
		});
	},

	handleResumeAll: function() {
		var self = this;
		this.busy = true;

		return callResumeAll().then(function(res) {
			ui.addNotification(null,
				E('p', {}, _('Resumed %d device(s).').format((res && res.resumed) || 0)), 'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Request failed: %s').format(err.message)), 'error');
		}).finally(function() {
			self.busy = false;
			return self.refresh();
		});
	},

	render: function(devices) {
		var self = this;

		/* The grid needs room for five columns; below that the wrapper scrolls
		   rather than letting the columns crush into each other. */
		var table = E('div', {
			'id': 'limcore-devices-table',
			'style': 'min-width:44rem'
		}, [ this.renderHeader() ].concat(this.renderRows(devices)));

		var resumeAll = E('button', {
			'id': 'limcore-devices-resume-all',
			'class': 'cbi-button cbi-button-positive',
			'style': devices.some(function(d) { return d.paused; }) ? '' : 'display:none',
			'click': ui.createHandlerFn(this, 'handleResumeAll')
		}, _('Resume all'));

		poll.add(function() { return self.refresh(); }, 10);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', { 'name': 'content' }, _('Device Control')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Pause or restore internet access for any device on the network. A paused device stays connected and can still reach the router itself, but no traffic leaves for the internet.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'style': 'overflow-x:auto' }, table)
			]),
			E('div', { 'class': 'cbi-page-actions' }, resumeAll)
		]);
	},

	/* Every change applies the moment its button is pressed, so the page has no
	   pending state for the standard footer to save or revert. */
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
