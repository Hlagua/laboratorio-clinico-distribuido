import { Directive, ElementRef, HostListener, inject } from '@angular/core';

/** Quita lo que no cumple el patrón mientras se escribe y avisa a ngModel con un nuevo evento input. */
function filtrar(el: HTMLInputElement, permitido: RegExp, maximo: number, unEspacio = false) {
  let limpio = [...el.value].filter((c) => permitido.test(c)).join('');
  // Nombres: sin espacio al inicio ni dos espacios seguidos.
  if (unEspacio) limpio = limpio.replace(/^\s+/, '').replace(/\s{2,}/g, ' ');
  limpio = limpio.slice(0, maximo);
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

/** Fecha de nacimiento: entre 1900 y hoy (el calendario no deja elegir fuera de ese rango). */
@Directive({ selector: 'input[type=date][nacimiento]', host: { min: '1900-01-01', '[max]': 'hoy' } })
export class Nacimiento {
  protected readonly hoy = new Date().toISOString().slice(0, 10);
}

/** ¿La fecha (AAAA-MM-DD) es un nacimiento posible? */
export function nacimientoValido(f: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(f) && f >= '1900-01-01' && f <= new Date().toISOString().slice(0, 10);
}

/** Solo letras (con tildes), espacios y apóstrofo; hasta 50 caracteres (nombres y apellidos). */
@Directive({ selector: 'input[soloLetras]', host: { maxlength: '50' } })
export class SoloLetras {
  private readonly el = inject(ElementRef<HTMLInputElement>);

  @HostListener('input')
  alEscribir() {
    filtrar(this.el.nativeElement, /[A-Za-zÁÉÍÓÚÜÑáéíóúüñ' ]/, 50, true);
  }
}
