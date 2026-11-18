import { Component, computed, inject, signal } from '@angular/core';
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
      <div class="marco" [class]="'marco rol-' + auth.rolActivo()">
        <aside class="lateral">
          <div class="marca">
            <span class="logo">⚕</span>
            <div><strong>Laboratorio Clínico</strong><small>Portal de {{ portal[auth.rolActivo()!] }}</small></div>
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
              <span class="badge-rol">{{ nombreRol[auth.rolActivo()!] }}</span>
              @if (auth.rolesDisponibles().length > 1) {
                <button class="secundario chico" (click)="eligiendo.set(true)">⇄ Cambiar de rol</button>
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
      @if (eligiendo()) {
        <div class="velo" (click)="eligiendo.set(false)">
          <div class="card modal" (click)="$event.stopPropagation()" role="dialog" aria-label="Cambiar de rol">
            <h2>¿Con qué rol desea trabajar?</h2>
            @for (r of auth.rolesDisponibles(); track r) {
              <button class="opcion" [class]="'opcion rol-' + r" [disabled]="r === auth.rolActivo()" (click)="cambiar(r)">
                <span class="punto"></span>{{ nombreRol[r] }}
                @if (r === auth.rolActivo()) { <small>actual</small> }
                @if (r === 'PACIENTE') { <small>abre el portal de pacientes</small> }
              </button>
            }
            <button class="secundario chico" (click)="eligiendo.set(false)">Cancelar</button>
          </div>
        </div>
      }
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
    .badge-rol { background: var(--verde); color: #fff; border-radius: 20px; padding: 3px 12px; font-size: 12px; font-weight: 600; }
    .velo { position: fixed; inset: 0; background: rgb(0 0 0 / 35%); display: grid; place-items: center; z-index: 50; padding: 16px; }
    .modal { width: min(380px, 100%); display: flex; flex-direction: column; gap: 8px; }
    .opcion { display: flex; align-items: center; gap: 10px; justify-content: flex-start; width: 100%;
              background: #fff; color: var(--tinta); border: 1px solid var(--borde); padding: 12px; }
    .opcion:hover:not(:disabled) { border-color: var(--verde); background: var(--verde-suave); }
    .opcion small { margin-left: auto; color: var(--gris); }
    .punto { width: 14px; height: 14px; border-radius: 50%; background: var(--verde); }
    .contingencia { background: var(--ambar-suave); color: var(--ambar); border-bottom: 1px solid #f0d68a; padding: 10px 24px; font-weight: 600; }
    main { padding: 24px; max-width: 1200px; }
    @media (max-width: 860px) {
      /* El menú arriba ocupa solo su alto; antes la fila se estiraba hasta llenar la pantalla. */
      .marco { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
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
  protected readonly portal: Record<Rol, string> = {
    PACIENTE: 'pacientes', LABORATORISTA: 'laboratorio', MEDICO: 'médicos', ADMIN: 'administración',
  };
  protected readonly eligiendo = signal(false);

  protected cambiar(r: Rol) {
    this.eligiendo.set(false);
    this.auth.cambiarRol(r);
  }
  protected readonly menu = computed(() => {
    const rol = this.auth.rolActivo();
    return MENU.filter((e) => rol && e.roles.includes(rol));
  });
}
