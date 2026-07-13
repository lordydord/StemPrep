const root = document.documentElement;
const themeButton = document.querySelector('.theme-toggle');
const menuButton = document.querySelector('.menu-toggle');
const navLinks = document.querySelector('#nav-links');

const preferredTheme = () => {
  const saved = localStorage.getItem('stemprep-theme');
  if (saved === 'light' || saved === 'dark') return saved;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
};

const applyTheme = (theme) => {
  root.dataset.theme = theme;
  themeButton.textContent = theme === 'dark' ? 'Light mode' : 'Dark mode';
  themeButton.setAttribute('aria-label', `Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`);
};

applyTheme(preferredTheme());

themeButton.addEventListener('click', () => {
  const next = root.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('stemprep-theme', next);
  applyTheme(next);
});

menuButton.addEventListener('click', () => {
  const isOpen = navLinks.classList.toggle('is-open');
  menuButton.setAttribute('aria-expanded', String(isOpen));
  menuButton.textContent = isOpen ? 'Close' : 'Menu';
});

navLinks.addEventListener('click', (event) => {
  if (event.target.closest('a') && navLinks.classList.contains('is-open')) {
    navLinks.classList.remove('is-open');
    menuButton.setAttribute('aria-expanded', 'false');
    menuButton.textContent = 'Menu';
  }
});

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const revealItems = document.querySelectorAll('.reveal');

if (reduceMotion || !('IntersectionObserver' in window)) {
  revealItems.forEach((item) => item.classList.add('is-visible'));
} else {
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      }
    });
  }, { threshold: 0.18 });

  revealItems.forEach((item) => observer.observe(item));
}
