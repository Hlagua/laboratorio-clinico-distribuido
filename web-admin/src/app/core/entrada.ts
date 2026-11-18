import { Directive, ElementRef, HostListener, inject } from '@angular/core';

/** Quita lo que no cumple el patrón mientras se escribe y avisa a ngModel con un nuevo evento input. */
function filtrar(el: HTMLInputElement, permitido: RegExp, maximo: number) {
  const limpio = [...el.value].filter((c) => permitido.test(c)).join('').slice(0, maximo);
  if (limpio !== el.value) {
    el.value = limpio;
    el.dispatchEvent(new Event('input'));
  }
}

/** Solo dígitos (cédula, teléfono). El largo máximo se toma de maxlength. */
@Directive({ selector: 'input[soloNumeros]', host: { inputmode: 'numeric' } })
export class SoloNumeros {
  private readonly el = inject(ElementRef<HTMLInputElement>);

  @HostListener('input')
  alEscribir() {
    filtrar(this.el.nativeElement, /\d/, this.el.nativeElement.maxLength > 0 ? this.el.nativeElement.maxLength : 20);
  }
}

/** Solo letras (con tildes), espacios y apóstrofo; hasta 50 caracteres (nombres y apellidos). */
@Directive({ selector: 'input[soloLetras]', host: { maxlength: '50' } })
export class SoloLetras {
  private readonly el = inject(ElementRef<HTMLInputElement>);

  @HostListener('input')
  alEscribir() {
    filtrar(this.el.nativeElement, /[A-Za-zÁÉÍÓÚÜÑáéíóúüñ' ]/, 50);
  }
}
