export const MODES = [
  {
    skill: "faker-mode",
    plugin: "pstack",
    reminder: "New task? Playbook match or rigor needed -> apply /faker-mode. Casual turn or user opts out -> don't.",
  },
];

const invocation = (skill) => new RegExp(`(?:^|\\s)/(?:[a-z0-9-]+:)?${skill}\\b`, "i");
const switchOff = (skill) => new RegExp(`(?:^|\\s)/(?:[a-z0-9-]+:)?${skill}\\s+off\\b`, "i");
const optOut = (skill) => {
  const words = skill.replace(/-/g, "[- ]");
  return new RegExp(`\\b(?:exit|leave|stop|disable|turn off|quit|drop|opt out of|no more)\\s+(?:the\\s+)?(?:/)?${words}\\b`, "i");
};

export function nextActiveModes(prompt, active) {
  const next = new Set(active);
  for (const { skill } of MODES) {
    if (switchOff(skill).test(prompt) || optOut(skill).test(prompt)) next.delete(skill);
    else if (invocation(skill).test(prompt)) next.add(skill);
  }
  return next;
}

export function reminderText(active) {
  const lines = MODES.filter((m) => active.has(m.skill)).map(
    (m) => `/${m.skill} is pinned for this session (${m.plugin}). ${m.reminder} The user can say "exit ${m.skill.replace(/-/g, " ")}" to unpin it.`,
  );
  return lines.length > 0 ? lines.join("\n") : null;
}
