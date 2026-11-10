import { Component, computed, inject } from '@angular/core';
import { RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { EstadoSistema } from './core/api';
import { AuthService, NOMBRE_ROL, Rol } from './core/auth';

interface Enlace { ruta: string; texto: string; roles: Rol[] }

const MENU: Enlace[] = [
  { ruta: '/inicio', texto: 'Inicio', roles: ['LABORATORISTA', 'MEDICO', 'ADMIN'] },
  { ruta: '/agenda', texto: 'Agenda del día', roles: ['LABORATORISTA', 'MEDICO', 'ADMIN'] },
  { ruta: '/solicitudes', texto: 'Solicitudes y resultados', roles: ['LABORATORISTA', 'MEDICO', 'ADMIN'] },
  { ruta: '/nueva-solicitud', texto: 'Nueva solicitud', roles: ['LABORATORISTA', 'MEDICO'] },
  { ruta: '/pacientes', texto: 'Pacientes y tratamientos', roles: ['MEDICO', 'ADMIN', 'LABORATORISTA'] },
  { ruta: '/pagos', texto: 'Pagos y reembolsos', roles: ['ADMIN'] },
  { ruta: '/usuarios', texto: 'Usuarios y roles', roles: ['ADMIN'] },
  { ruta: '/catalogo', texto: 'Catálogo y franjas', roles: ['ADMIN'] },
  { ruta: '/conocimiento', texto: 'Base de conocimientos', roles: ['MEDICO', 'ADMIN'] },
  { ruta: '/reportes', texto: 'Reportes', roles: ['ADMIN', 'MEDICO'] },
  { ruta: '/auditoria', texto: 'Auditoría y correos', roles: ['ADMIN'] },
];

@Component({
  selector: 'app-root',
  imports: [RouterOutlet, RouterLink, RouterLinkActive],
  template: `
    @if (auth.autenticado()) {
      <div class="marco">
        <aside class="lateral">
          <div class="marca">
            <span class="logo">⚕</span>
            <div><strong>Laboratorio Clínico</strong><small>Sistema transaccional</small></div>
          </div>
          <nav>
            @for (e of menu(); track e.ruta) {
              <a [routerLink]="e.ruta" routerLinkActive="activo">{{ e.texto }}</a>
            }
          </nav>
          <div class="pie-lateral">
            @if (estado.instancia()) {
              <small>Atendido por {{ estado.instancia() }}{{ estado.vm() ? ' · ' + estado.vm() : '' }}</small>
            }
          </div>
        </aside>
        <div class="principal">
          <header class="cabecera">
            <div>
              <strong>{{ auth.usuario()?.nombre }}</strong>
              <small class="muted">{{ auth.usuario()?.email }}</small>
            </div>
            <div class="acciones">
              @if (auth.rolesPersonal().length > 1) {
                <label class="rol">Trabajar como
                  <select [value]="auth.rolActivo()" (change)="auth.cambiarRol($any($event.target).value)">
                    @for (r of auth.rolesPersonal(); track r) { <option [value]="r">{{ nombreRol[r] }}</option> }
                  </select>
                </label>
              } @else {
                <span class="badge">{{ nombreRol[auth.rolActivo()!] }}</span>
              }
              <button class="secundario chico" (click)="auth.logout()">Salir</button>
            </div>
          </header>
          @if (estado.origenDatos() === 'supabase') {
            <div class="contingencia">
              ⚠ Modo contingencia: la base principal no está disponible. Los datos se leen de la réplica (Supabase)
              y las operaciones de escritura están deshabilitadas temporalmente.
            </div>
          }
          <main><router-outlet /></main>
        </div>
      </div>
    } @else {
      <router-outlet />
    }
  `,
  styles: `
    .marco { display: grid; grid-template-columns: 240px 1fr; min-height: 100vh; }
    .lateral { background: var(--verde-oscuro); color: #fff; display: flex; flex-direction: column; position: sticky; top: 0; height: 100vh; }
    .marca { display: flex; gap: 10px; align-items: center; padding: 18px 16px; border-bottom: 1px solid rgb(255 255 255 / 12%); }
    .marca small { display: block; opacity: .75; font-size: 12px; }
    .logo { font-size: 26px; }
    nav { display: flex; flex-direction: column; padding: 10px 8px; gap: 2px; overflow-y: auto; }
    nav a { color: #e6f2ee; text-decoration: none; padding: 9px 12px; border-radius: 6px; }
    nav a:hover { background: rgb(255 255 255 / 10%); }
    nav a.activo { background: #fff; color: var(--verde-oscuro); font-weight: 600; }
    .pie-lateral { margin-top: auto; padding: 12px 16px; opacity: .7; font-size: 12px; }
    .principal { min-width: 0; }
    .cabecera { background: #fff; border-bottom: 1px solid var(--borde); padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
    .cabecera small { display: block; }
    .acciones { display: flex; gap: 12px; align-items: center; }
    .rol { display: flex; gap: 8px; align-items: center; font-size: 13px; color: var(--gris); }
    .contingencia { background: var(--ambar-suave); color: var(--ambar); border-bottom: 1px solid #f0d68a; padding: 10px 24px; font-weight: 600; }
    main { padding: 24px; max-width: 1200px; }
    @media (max-width: 860px) {
      .marco { grid-template-columns: 1fr; }
      .lateral { position: static; height: auto; }
      nav { flex-direction: row; flex-wrap: wrap; }
      main { padding: 16px; }
    }
  `,
})
export class App {
  protected readonly auth = inject(AuthService);
  protected readonly estado = inject(EstadoSistema);
  protected readonly nombreRol = NOMBRE_ROL;
  protected readonly menu = computed(() => {
    const rol = this.auth.rolActivo();
    return MENU.filter((e) => rol && e.roles.includes(rol));
  });
}
