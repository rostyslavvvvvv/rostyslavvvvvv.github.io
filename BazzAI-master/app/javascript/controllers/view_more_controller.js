import { Controller } from '@hotwired/stimulus';

// Connects to data-controller="view-more"
export default class extends Controller {
  static targets = ['cards', 'more', 'all', 'remove'];
  more(event) {
    event.preventDefault();
    this.moreTarget.classList.add('d-none');
    this.allTarget.classList.remove('d-none');
    this.cardsTargets.forEach((element, index) => {
      if (index < 5) {
        element.classList.remove('d-none');
      }
    });
  }
  all(event) {
    event.preventDefault();
    this.allTarget.classList.add('d-none');
    this.moreTarget.classList.add('d-none');
    this.cardsTargets.forEach((element) => {
      element.classList.remove('d-none');
    });
  }
  remove(event) {
    const index = parseInt(event.target.dataset.index);
    const cardToRemove = this.cardsTargets[index];
    cardToRemove.remove();

    this.cardsTargets.forEach((element, idx) => {
      element.dataset.index = idx;
    });

    this.removeTargets.forEach((element, idx) => {
      element.dataset.index = idx;
    });

    const cardsVisible = this.cardsTargets.filter((element) => {
      return !element.classList.contains('d-none');
    });

    const nextCardIndex =
      parseInt(cardsVisible[cardsVisible.length - 1].dataset.index) + 1;
    const nextCard = this.cardsTargets[nextCardIndex];

    if (nextCard) {
      nextCard.classList.remove('d-none');
    }

    if (cardsVisible.length === this.cardsTargets.length - 1) {
      this.allTarget.classList.add('d-none');
      this.moreTarget.classList.add('d-none');
      return;
    }
  }

  submit(event) {
    event.preventDefault();

    const form = event.target;
    const url = form.getAttribute('action');
    const method = form.getAttribute('method');

    fetch(url, {
      method: method,
      headers: { Accept: 'text/vnd.turbo-stream.html' },
    })
      .then((response) => response.text())
      .then((html) => {
        const turboFrame = form.closest('turbo-frame');
        turboFrame.innerHTML = html;
      })
      .catch((error) => {
        console.error(error);
      });
  }
}
