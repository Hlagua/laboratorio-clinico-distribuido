import { Component, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { mensajeError } from '../core/api';
import { AuthService } from '../core/auth';

@Component({
  selector: 'app-login',
  imports: [FormsModule],
  template: `
    <div class="fondo">
      <form class="card caja" (ngSubmit)="entrar()">
        <div class="marca"><span>⚕</span> Laboratorio Clínico</div>
        <h1>Sistema transaccional</h1>
        <p class="sub">Acceso para laboratoristas, médicos y administradores.</p>
        @if (error()) { <div class="alerta error">{{ error() }}</div> }
        <div class="campo">
          <label for="email">Correo</label>
          <input id="email" name="email" type="email" autocomplete="username" required [(ngModel)]="email" />
        </div>
        <div class="campo">
          <label for="clave">Contraseña</label>
          <input id="clave" name="clave" type="password" autocomplete="current-password" required [(ngModel)]="password" />
        </div>
        <button type="submit" [disabled]="cargando() || !email || !password">
          {{ cargando() ? 'Ingresando…' : 'Ingresar' }}
        </button>
        <p class="muted pie">¿Es paciente? Use el <a href="/">portal de pacientes</a>.</p>
      </form>
    </div>
  `,
  styles: `
    .fondo { min-height: 100vh; display: grid; place-items: center; padding: 16px;
             background: linear-gradient(160deg, var(--verde-oscuro), var(--verde) 60%, #2f8f6f); }
    .caja { width: min(400px, 100%); padding: 28px; }
    .marca { color: var(--verde); font-weight: 700; margin-bottom: 14px; font-size: 15px; }
    .marca span { font-size: 22px; }
    button { width: 100%; justify-content: center; margin-top: 6px; }
    .pie { margin: 16px 0 0; font-size: 13px; text-align: center; }
  `,
})
export class Login {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  protected email = '';
  protected password = '';
  protected readonly cargando = signal(false);
  protected readonly error = signal('');

  async entrar() {
    this.cargando.set(true);
    this.error.set('');
    try {
      await this.auth.login(this.email.trim().toLowerCase(), this.password);
      this.router.navigateByUrl('/inicio');
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.cargando.set(false);
    }
  }
}
