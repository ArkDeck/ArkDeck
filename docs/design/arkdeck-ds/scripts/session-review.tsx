import { createRoot } from "react-dom/client";
import { SessionSurfaces } from "../../../../.design-sync/previews/SessionSurfaces";

const params = new URLSearchParams(location.search);
const language = params.get("lang") === "en" ? "en" : "zh-Hans";
const appearance = params.get("appearance") === "dark" ? "dark" : "light";
document.documentElement.lang = language;
document.documentElement.dataset.theme = appearance;
const link = document.querySelector<HTMLAnchorElement>("#appearance");
if (link) {
  link.href = `?lang=${language}&appearance=${appearance === "light" ? "dark" : "light"}`;
  link.textContent = language === "en" ? "Switch appearance" : "切换外观";
}
for (const [id, lang] of [["language-zh", "zh-Hans"], ["language-en", "en"]]) {
  const anchor = document.querySelector<HTMLAnchorElement>(`#${id}`);
  if (anchor) anchor.href = `?lang=${lang}&appearance=${appearance}`;
}
const title = document.getElementById("review-title");
const boundary = document.getElementById("review-boundary");
if (title) title.textContent = language === "en" ? "ArkDeck · Component review" : "ArkDeck · 组件核对";
if (boundary) boundary.textContent = language === "en"
  ? "Design samples only · no Runtime or file access" : "仅设计样本 · 不访问 Runtime 或文件";
createRoot(document.getElementById("root")!).render(<SessionSurfaces language={language} />);
