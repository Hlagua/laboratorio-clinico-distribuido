import { computed, inject, Injectable, signal } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Router } from '@angular/router';
import { firstValueFrom } from 'rxjs';

export type Rol = 'PACIENTE' | 'LABORATORISTA' | 'MEDICO' | 'ADMIN';

export interface Usuario {
  usuario_id: number;
  persona_id: number;
  nombre: string;
  email: string;
  roles: Rol[];
  paciente_id: number | null;
  medico_id: number | null;
  laboratorista_id: number | null;
}

/** Roles que usan este sistema; el paciente usa el portal Flutter. */
export const ROLES_PERSONAL: Rol[] = ['LABORATORISTA', 'MEDICO', 'ADMIN'];

export const NOMBRE_ROL: Record<Rol, string> = {
  PACIENTE: 'Paciente',
  LABORATORISTA: 'Laboratorista',
  MEDICO: 'Médico tratante',
  ADMIN: 'Administrador',
};

const CLAVE = 'lab-admin-sesion';
/** Sesión del portal de pacientes (Flutter). Mismo origen, mismo sessionStorage. */
const CLAVE_PORTAL = 'portal-sesion';
/** Login único de la plataforma (portal Flutter): todos los roles ingresan ahí. */
export const URL_LOGIN = '/ingresar';

/**
 * Sesión del personal. Una persona puede tener varios roles: el rol activo
 * viaja en la cabecera X-Rol-Activo y la API autoriza con él.
 */
@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly http = inject(HttpClient);
  private readonly router = inject(Router);

  readonly token = signal<string | null>(null);
  readonly usuario = signal<Usuario | null>(null);
  readonly rolActivo = signal<Rol | null>(null);

  readonly rolesPersonal = computed(() => (this.usuario()?.roles ?? []).filter((r) => ROLES_PERSONAL.includes(r)));
  /** Roles a los que se puede cambiar sin volver a ingresar (incluye el de paciente). */
  readonly rolesDisponibles = computed(() =>
    (this.usuario()?.roles ?? []).filter((r) => ROLES_PERSONAL.includes(r) || r === 'PACIENTE'));
  readonly autenticado = computed(() => !!this.token() && !!this.rolActivo());

  constructor() {
    try {
      const guardada = sessionStorage.getItem(CLAVE);
      if (guardada) {
        const s = JSON.parse(guardada);
        this.token.set(s.token);
        this.usuario.set(s.usuario);
        this.rolActivo.set(s.rolActivo);
      }
    } catch {
      /* almacenamiento no disponible: la sesión vive solo en memoria */
    }
  }

  async login(email: string, password: string): Promise<void> {
    const r = await firstValueFrom(
      this.http.post<{ token: string; usuario: Usuario }>('/api/auth/login', { email, password }),
    );
    const roles = r.usuario.roles.filter((x) => ROLES_PERSONAL.includes(x));
    if (!roles.length) {
      throw new Error('Este sistema es para el personal del laboratorio. Los pacientes usan el portal público.');
    }
    this.token.set(r.token);
    this.usuario.set(r.usuario);
    this.rolActivo.set(roles[0]);
    this.guardar();
  }

  cambiarRol(rol: Rol): void {
    if (rol === 'PACIENTE' && this.usuario()?.roles.includes(rol)) {
      // El paciente usa el portal Flutter: se le pasa la sesión y se navega allá.
      try {
        sessionStorage.setItem(CLAVE_PORTAL, JSON.stringify({ token: this.token(), usuario: this.usuario() }));
      } catch {
        /* sin almacenamiento: tendrá que ingresar de nuevo */
      }
      window.location.href = '/panel';
      return;
    }
    if (this.usuario()?.roles.includes(rol)) {
      this.rolActivo.set(rol);
      this.guardar();
      this.router.navigateByUrl('/inicio');
    }
  }

  tiene(...roles: Rol[]): boolean {
    const r = this.rolActivo();
    return !!r && roles.includes(r);
  }

  logout(): void {
    this.token.set(null);
    this.usuario.set(null);
    this.rolActivo.set(null);
    try {
      sessionStorage.removeItem(CLAVE);
      sessionStorage.removeItem(CLAVE_PORTAL);
    } catch {
      /* sin almacenamiento */
    }
    window.location.href = URL_LOGIN;
  }

  private guardar(): void {
    try {
      sessionStorage.setItem(
        CLAVE,
        JSON.stringify({ token: this.token(), usuario: this.usuario(), rolActivo: this.rolActivo() }),
      );
    } catch {
      /* sin almacenamiento */
    }
  }
}
