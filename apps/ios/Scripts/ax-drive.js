function run(argv) {
  const [pid, command, ...rest] = argv;
  const se = Application('System Events');
  const proc = se.processes.whose({ unixId: Number(pid) })[0];
  const entire = () => {
    try { return proc.windows[0].entireContents(); } catch (error) { return []; }
  };
  const find = (identifier) => {
    for (const element of entire()) {
      try {
        if (element.attributes.byName('AXIdentifier').value() === identifier) return element;
      } catch (error) {}
    }
    return null;
  };
  const identifiers = () => {
    const found = [];
    for (const element of entire()) {
      try {
        const identifier = element.attributes.byName('AXIdentifier').value();
        if (identifier) found.push(identifier);
      } catch (error) {}
    }
    return found;
  };
  const front = () => {
    proc.frontmost = true;
    try { proc.windows[0].actions.byName('AXRaise').perform(); } catch (error) {}
    delay(0.4);
  };
  const press = (element) => {
    front();
    try {
      element.actions.byName('AXPress').perform();
      return;
    } catch (error) {}
    const [x, y] = element.position();
    const [w, h] = element.size();
    se.click({ at: [Math.round(x + w / 2), Math.round(y + h / 2)] });
  };
  const waitFor = (names, seconds) => {
    const deadline = Date.now() + seconds * 1000;
    do {
      const present = identifiers();
      const hit = names.find((name) => present.includes(name));
      if (hit) return hit;
      delay(1);
    } while (Date.now() < deadline);
    return '';
  };
  switch (command) {
    case 'ids':
      return identifiers().join('\n');
    case 'wait': {
      const hit = waitFor(rest[0].split(','), Number(rest[1]));
      if (!hit) throw new Error('timeout waiting for ' + rest[0]);
      return hit;
    }
    case 'waitany':
      return waitFor(rest[0].split(','), Number(rest[1]));
    case 'click': {
      const element = find(rest[0]);
      if (!element) throw new Error('missing ' + rest[0]);
      press(element);
      return 'clicked ' + rest[0];
    }
    case 'type': {
      front();
      se.keystroke(rest[0]);
      return 'typed';
    }
    case 'value': {
      const element = find(rest[0]);
      if (!element) return '';
      try { return String(element.attributes.byName('AXValue').value()); } catch (error) { return ''; }
    }
    case 'shot': {
      front();
      const window = proc.windows[0];
      const [x, y] = window.position();
      const [w, h] = window.size();
      const app = Application.currentApplication();
      app.includeStandardAdditions = true;
      app.doShellScript('/usr/sbin/screencapture -x -R' + [x, y, w, h].map(Math.round).join(',') + ' ' + JSON.stringify(rest[0]));
      return rest[0];
    }
    default:
      throw new Error('unknown command ' + command);
  }
}
