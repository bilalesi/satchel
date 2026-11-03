// One place for the facts every page repeats. Change a price or a link here only.
export const site = {
  name: "Satchel",
  repo: "https://github.com/bilalesi/satchel",
  download: "https://github.com/bilalesi/satchel/releases/latest",
  advisories: "https://github.com/bilalesi/satchel/security/advisories/new",
  // Empty until checkout is set up: the pricing page then offers the trial only.
  buyUrl: "",
  requirements: "macOS 15 or newer, Apple silicon or Intel",
  trialDays: 14,
  // One plan. Checkout fees and taxes are added on top at checkout.
  price: "€20",
  fees: "+ checkout fees",
} as const;
