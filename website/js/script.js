document.getElementById("year").textContent = new Date().getFullYear();

const navToggle = document.getElementById("navToggle");
const nav = document.getElementById("nav");

navToggle.addEventListener("click", () => {
  const isOpen = nav.classList.toggle("open");
  navToggle.setAttribute("aria-expanded", String(isOpen));
});

nav.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    nav.classList.remove("open");
    navToggle.setAttribute("aria-expanded", "false");
  });
});

const contactForm = document.getElementById("contactForm");
const formStatus = document.getElementById("formStatus");

if (contactForm) {
  contactForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const submitButton = contactForm.querySelector('button[type="submit"]');
    submitButton.disabled = true;
    formStatus.textContent = "Envoi en cours...";
    formStatus.className = "form-status";

    try {
      const response = await fetch("contact.php", {
        method: "POST",
        headers: { Accept: "application/json" },
        body: new FormData(contactForm),
      });

      const data = await response.json();

      formStatus.textContent = data.message;
      formStatus.classList.add(data.success ? "success" : "error");

      if (data.success) {
        contactForm.reset();
      }
    } catch (error) {
      formStatus.textContent =
        "Impossible d'envoyer le message pour le moment. Merci de réessayer ou de m'écrire directement à nicolas@allsafe.ovh.";
      formStatus.classList.add("error");
    } finally {
      submitButton.disabled = false;
    }
  });
}
