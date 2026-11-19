import { Component, computed, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, mensajeError } from '../core/api';
import { AuthService } from '../core/auth';
import { hora, hoyIso } from '../core/formato';
import { MedicoAgenda } from '../core/modelos';

interface Bloque { inicio: string; fin: string; minutos: number }
interface Turno { franja_id: number; fecha: string; hora_inicio: string; hora_fin: string; capacidad: number; ocupados: number }

const DIAS = [
  { n: 1, t: 'Lun' }, { n: 2, t: 'Mar' }, { n: 3, t: 'Mié' }, { n: 4, t: 'Jue' }, { n: 5, t: 'Vie' }, { n: 6, t: 'Sáb' }, { n: 7, t: 'Dom' },
];

/**
 * Horario del médico: elige qué días trabaja, en qué horas y cuánto dura cada consulta
 * (por ejemplo, mañanas cada 30 min y tardes cada hora). El administrador lo hace por cualquier médico.
 */
@Component({
  selector: 'app-horario',
  imports: [FormsModule],
  template: `
    <h1>{{ auth.tiene('MEDICO') ? 'Mi horario' : 'Horarios de los médicos' }}</h1>
    <p class="sub">Elija los días y los bloques de atención. Cada bloque tiene su propia duración de consulta.
      Los turnos que ya existen no se duplican ni se pisan.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <form class="card" (ngSubmit)="generar()">
      @if (auth.tiene('ADMIN')) {
        <div class="campo"><label for="hm">Médico</label>
          <select id="hm" name="hm" [(ngModel)]="medicoId" (ngModelChange)="cargar()">
            @for (m of medicos(); track m.medico_id) { <option [ngValue]="m.medico_id">Dr(a). {{ m.nombre }} · {{ m.especialidad }}</option> }
          </select></div>
      }
      <div class="fila">
        <div class="campo"><label for="hd">Desde</label><input id="hd" name="hd" type="date" [min]="hoy" [(ngModel)]="desde" required /></div>
        <div class="campo"><label for="hh">Hasta (máx. 62 días)</label><input id="hh" name="hh" type="date" [min]="desde" [(ngModel)]="hasta" required /></div>
      </div>
      <div class="campo"><label>Días que atiende</label>
        <div class="dias">
          @for (d of dias; track d.n) {
            <label class="dia"><input type="checkbox" [checked]="elegidos().has(d.n)" (change)="alternarDia(d.n)" /> {{ d.t }}</label>
          }
        </div></div>
      <label>Bloques de atención</label>
      @for (b of bloques; track $index; let i = $index) {
        <div class="fila bloque">
          <div class="campo"><label [for]="'bi' + i">Desde</label><input [id]="'bi' + i" [name]="'bi' + i" type="time" [(ngModel)]="b.inicio" required /></div>
          <div class="campo"><label [for]="'bf' + i">Hasta</label><input [id]="'bf' + i" [name]="'bf' + i" type="time" [(ngModel)]="b.fin" required /></div>
          <div class="campo"><label [for]="'bm' + i">Cada consulta dura</label>
            <select [id]="'bm' + i" [name]="'bm' + i" [(ngModel)]="b.minutos">
              @for (m of duraciones; track m) { <option [ngValue]="m">{{ m }} min</option> }
            </select></div>
          <div class="campo"><button type="button" class="secundario chico" (click)="quitarBloque(i)" [disabled]="bloques.length === 1">Quitar</button></div>
        </div>
      }
      <div class="fila">
        <button type="button" class="secundario chico" (click)="agregarBloque()" [disabled]="bloques.length >= 6">+ Agregar bloque</button>
        <button type="submit" [disabled]="ocupado() || !elegidos().size">Generar turnos</button>
      </div>
    </form>

    <div class="card">
      <h2>Próximos turnos (14 días)</h2>
      @for (d of porDia(); track d.fecha) {
        <div class="dia-turnos">
          <strong>{{ d.fecha }}</strong>
          <div class="chips">
            @for (t of d.turnos; track t.franja_id) {
              <span [class]="t.ocupados ? 'chip ocupado' : 'chip'">{{ hora(t.hora_inicio) }}–{{ hora(t.hora_fin) }}
                @if (t.ocupados) { · con cita } @else {
                  <button type="button" class="x" (click)="quitar(t)" [attr.aria-label]="'Quitar turno ' + hora(t.hora_inicio)">×</button> }
              </span>
            }
          </div>
        </div>
      } @empty { <p class="muted">No hay turnos en los próximos 14 días.</p> }
    </div>
  `,
  styles: `
    .dias { display: flex; flex-wrap: wrap; gap: 10px; }
    .dia { display: flex; gap: 4px; align-items: center; font-weight: normal; }
    .bloque { align-items: end; }
    .dia-turnos { padding: 6px 0; border-bottom: 1px solid var(--borde); }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 4px; }
    .chip { border: 1px solid var(--borde); border-radius: 12px; padding: 2px 8px; font-size: 13px; }
    .chip.ocupado { background: var(--verde-suave); border-color: var(--verde); }
    .x { background: none; border: 0; color: var(--rojo); padding: 0 0 0 4px; cursor: pointer; font-size: 14px; }
  `,
})
export class Horario implements OnInit {
  private readonly api = inject(Api);
  protected readonly auth = inject(AuthService);
  protected readonly hora = hora;
  protected readonly dias = DIAS;
  protected readonly duraciones = [15, 20, 30, 45, 60, 90, 120];
  protected readonly hoy = hoyIso();
  protected desde = hoyIso();
  protected hasta = new Date(Date.now() + 27 * 86_400_000).toISOString().slice(0, 10);
  protected bloques: Bloque[] = [{ inicio: '08:00', fin: '12:00', minutos: 30 }, { inicio: '14:00', fin: '18:00', minutos: 60 }];
  protected readonly elegidos = signal(new Set([1, 2, 3, 4, 5]));
  protected readonly medicos = signal<MedicoAgenda[]>([]);
  protected medicoId: number | null = null;
  protected readonly turnos = signal<Turno[]>([]);
  protected readonly porDia = computed(() => {
    const mapa = new Map<string, Turno[]>();
    for (const t of this.turnos()) mapa.set(t.fecha, [...(mapa.get(t.fecha) ?? []), t]);
    return [...mapa.entries()].map(([fecha, turnos]) => ({ fecha, turnos }));
  });
  protected readonly error = signal('');
  protected readonly aviso = signal('');
  protected readonly ocupado = signal(false);

  async ngOnInit() {
    if (this.auth.tiene('ADMIN')) {
      this.medicos.set(await this.api.get<MedicoAgenda[]>('/api/citas/medicos'));
      this.medicoId = this.medicos()[0]?.medico_id ?? null;
    }
    await this.cargar();
  }

  async cargar() {
    try {
      this.turnos.set(await this.api.get<Turno[]>('/api/citas/horario',
        { dias: 14, ...(this.auth.tiene('ADMIN') ? { medico_id: this.medicoId } : {}) }));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }

  alternarDia(n: number) {
    const s = new Set(this.elegidos());
    if (s.has(n)) s.delete(n); else s.add(n);
    this.elegidos.set(s);
  }

  agregarBloque() {
    this.bloques = [...this.bloques, { inicio: '14:00', fin: '16:00', minutos: 30 }];
  }

  quitarBloque(i: number) {
    this.bloques = this.bloques.filter((_, j) => j !== i);
  }

  async generar() {
    this.error.set('');
    this.aviso.set('');
    this.ocupado.set(true);
    try {
      const r = await this.api.post<{ franjas_creadas: number; omitidas: number }>('/api/citas/horario', {
        desde: this.desde, hasta: this.hasta, dias: [...this.elegidos()].sort(), bloques: this.bloques,
        ...(this.auth.tiene('ADMIN') ? { medico_id: this.medicoId } : {}),
      });
      this.aviso.set(`Se crearon ${r.franjas_creadas} turnos` + (r.omitidas ? ` (${r.omitidas} ya existían o se cruzaban con otros).` : '.'));
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.ocupado.set(false);
    }
  }

  async quitar(t: Turno) {
    try {
      await this.api.delete(`/api/citas/franjas/${t.franja_id}`);
      this.turnos.update((x) => x.filter((y) => y.franja_id !== t.franja_id));
    } catch (e) {
      this.error.set(mensajeError(e));
    }
  }
}
