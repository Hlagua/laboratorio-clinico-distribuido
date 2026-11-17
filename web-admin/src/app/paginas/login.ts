import { Component, OnInit } from '@angular/core';
import { URL_LOGIN } from '../core/auth';

/**
 * El login es uno solo para toda la plataforma: /ingresar (portal Flutter).
 * Ahí se elige el rol si la persona tiene varios y, si es del personal,
 * vuelve a /admin con la sesión ya iniciada. Esta ruta solo redirige.
 */
@Component({
  selector: 'app-login',
  template: `<p class="redirigiendo">Redirigiendo al inicio de sesión…</p>`,
  styles: `.redirigiendo { padding: 32px; text-align: center; color: var(--gris); }`,
})
export class Login implements OnInit {
  ngOnInit() {
    window.location.replace(URL_LOGIN);
  }
}
