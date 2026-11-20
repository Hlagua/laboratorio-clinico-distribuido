import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { Router } from '@angular/router';
import { Api } from './api';
import { AuthService } from './auth';
import { fechaHora } from './formato';

interface Aviso {
  notificacion_id: number;
  tipo: string;
  asunto: string;
  cuerpo: string;
  estado: string;
  created_at: string;
  rol: string;
  /** Adónde lleva el aviso: su solicitud o las citas. */
  enlace: { tipo: 'solicitud' | 'citas'; solicitud_id: number | null } | null;
}

/** Centro de notificaciones: los mismos avisos que se envían por correo al usuario. */
@Component({
  selector: 'app-campana',
  template: `
    <div class="campana">
      <button type="button" class="secundario chico" (click)="alternar()" [attr.aria-expanded]="abierta()" aria-label="Notificaciones">
        Avisos @if (nuevos()) { <span class="cuenta">{{ nuevos() }}</span> }
      </button>
      @if (abierta()) {
        <div class="panel card" role="dialog" aria-label="Notificaciones">
          <div class="entre"><strong>Notificaciones</strong><small class="muted">también llegan a su correo</small></div>
          @for (a of avisos(); track a.notificacion_id) {
            <div class="aviso" [class.nuevo]="a.notificacion_id > vista" [class.enlace]="a.enlace" (click)="ir(a)"
                 [attr.role]="a.enlace ? 'link' : null" [attr.tabindex]="a.enlace ? 0 : null" (keydown.enter)="ir(a)">
              <strong>{{ a.asunto }}</strong>
              <p>{{ a.cuerpo }}</p>
              <small class="muted">{{ fechaHora(a.created_at) }} ·
                {{ a.estado === 'ENVIADA' ? 'enviado al correo' : a.estado === 'PENDIENTE' ? 'enviándose' : 'no se pudo enviar' }}</small>
            </div>
          } @empty { <p class="muted">No tiene notificaciones.</p> }
        </div>
      }
    </div>
  `,
  styles: `
    .campana { position: relative; }
    .cuenta { background: var(--rojo); color: #fff; border-radius: 10px; padding: 0 6px; font-size: 11px; margin-left: 4px; }
    .panel { position: absolute; right: 0; top: 36px; width: min(360px, 90vw); max-height: 420px; overflow-y: auto; z-index: 40; }
    .aviso { border-top: 1px solid var(--borde); padding: 8px 0; }
    .aviso p { margin: 2px 0; font-size: 13px; }
    .aviso.nuevo { background: var(--verde-suave); margin: 0 -8px; padding: 8px; }
    .aviso.enlace { cursor: pointer; }
    .aviso.enlace:hover strong { text-decoration: underline; color: var(--verde); }
  `,
})
export class Campana implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  protected readonly fechaHora = fechaHora;
  protected readonly avisos = signal<Aviso[]>([]);
  protected readonly abierta = signal(false);
  protected vista = 0;
  private readonly clave = () => `notificaciones-vistas-${this.auth.usuario()?.usuario_id}`;
  protected readonly nuevos = computed(() => this.avisos().filter((a) => a.notificacion_id > this.vista).length);

  ngOnInit() {
    try {
      this.vista = Number(localStorage.getItem(this.clave()) ?? 0);
    } catch {
      this.vista = 0;
    }
    this.cargar();
  }

  private async cargar() {
    try {
      this.avisos.set(await this.api.get<Aviso[]>('/api/notificaciones/mias'));
    } catch {
      /* en contingencia la campana queda vacía */
    }
  }

  /** Lleva a lo que avisa la notificación (para todos los roles), sin tener que buscarlo. */
  protected ir(a: Aviso) {
    if (!a.enlace) return;
    if (a.enlace.tipo === 'solicitud' && a.enlace.solicitud_id) this.router.navigate(['/solicitudes', a.enlace.solicitud_id]);
    else this.router.navigate(['/agenda']);
    this.alternar();
  }

  async alternar() {
    if (this.abierta()) {
      this.abierta.set(false);
      // Al cerrar, lo visto deja de contarse como nuevo.
      const ultimo = this.avisos()[0]?.notificacion_id ?? this.vista;
      this.vista = ultimo;
      try {
        localStorage.setItem(this.clave(), String(ultimo));
      } catch {
        /* sin almacenamiento */
      }
      this.avisos.update((x) => [...x]);
      return;
    }
    await this.cargar();
    this.abierta.set(true);
  }
}
