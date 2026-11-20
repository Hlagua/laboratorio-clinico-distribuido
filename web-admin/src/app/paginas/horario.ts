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
      Puede hacerlo por días de la semana en un rango (por ejemplo, de lunes a viernes) o por fechas sueltas
      (por ejemplo, solo el sábado 28 de 08:00 a 11:00). Los turnos que ya existen no se duplican ni se pisan.</p>
    @if (error()) { <div class="alerta error">{{ error() }}</div> }
    @if (aviso()) { <div class="alerta ok">{{ aviso() }}</div> }

    <form class="card" (ngSubmit)="generar()">
      @if (auth.tiene('ADMIN')) {
        <div class="campo"><label for="hm">Médico</label>
          <select id="hm" name="hm" [(ngModel)]="medicoId" (ngModelChange)="cargar()">
            @for (m of medicos(); track m.medico_id) { <option [ngValue]="m.medico_id">Dr(a). {{ m.nombre }} · {{ m.especialidad }}</option> }
          </select></div>
      }
      <div class="modos" role="radiogroup" aria-label="Cómo elegir los días">
        <label><input type="radio" name="modo" value="semana" [(ngModel)]="modo" /> Días de la semana en un rango</label>
        <label><input type="radio" name="modo" value="fechas" [(ngModel)]="modo" /> Fechas sueltas</label>
      </div>
      @if (modo === 'semana') {
        <div class="fila">
          <div class="campo"><label for="hd">Desde</label><input id="hd" name="hd" type="date" [min]="hoy" [(ngModel)]="desde" required /></div>
          <div class="campo"><label for="hh">Hasta (máx. 3 meses)</label><input id="hh" name="hh" type="date" [min]="desde" [max]="limite" [(ngModel)]="hasta" required /></div>
        </div>
        <div class="campo"><label>Días que atiende</label>
          <div class="dias">
            @for (d of dias; track d.n) {
              <label class="dia"><input type="checkbox" [checked]="elegidos().has(d.n)" (change)="alternarDia(d.n)" /> {{ d.t }}</label>
            }
          </div></div>
      } @else {
        <div class="fila">
          <div class="campo"><label for="hf">Agregar fecha</label>
            <input id="hf" name="hf" type="date" [min]="hoy" [max]="limite" [(ngModel)]="fechaNueva" /></div>
          <div class="campo"><button type="button" class="secundario chico" (click)="agregarFecha()" [disabled]="!fechaNueva">Agregar</button></div>
        </div>
        <div class="chips">
          @for (f of fechas(); track f) {
            <span class="chip">{{ diaSemana(f) }} {{ f }}
              <button type="button" class="x" (click)="quitarFecha(f)" [attr.aria-label]="'Quitar ' + f">×</button></span>
          } @empty { <span class="muted">Agregue una o más fechas.</span> }
        </div>
      }
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
        <button type="submit" [disabled]="ocupado() || (modo === 'semana' ? !elegidos().size : !fechas().length)">Generar turnos</button>
      </div>
    </form>

    <div class="card">
      <div class="entre"><h2>Próximos turnos</h2>
        <select [(ngModel)]="diasVista" (ngModelChange)="cargar()" aria-label="Cuántos días ver">
          <option [ngValue]="14">14 días</option><option [ngValue]="30">30 días</option><option [ngValue]="90">3 meses</option>
        </select></div>
      <p class="muted">Para cambiar el horario de un día: quite sus turnos libres y vuelva a generarlo con las horas nuevas.
        Los turnos que ya tienen cita se conservan.</p>
      @for (d of porDia(); track d.fecha) {
        <div class="dia-turnos">
          <div class="entre"><strong>{{ diaSemana(d.fecha) }} {{ d.fecha }}</strong>
            @if (libres(d.turnos)) {
              <button type="button" class="secundario chico" (click)="quitarDia(d.fecha)">Quitar los {{ libres(d.turnos) }} libres de este día</button>
            }</div>
          <div class="chips">
            @for (t of d.turnos; track t.franja_id) {
              <span [class]="t.ocupados ? 'chip ocupado' : 'chip'">{{ hora(t.hora_inicio) }}–{{ hora(t.hora_fin) }}
                @if (t.ocupados) { · con cita } @else {
                  <button type="button" class="x" (click)="quitar(t)" [attr.aria-label]="'Quitar turno ' + hora(t.hora_inicio)">×</button> }
              </span>
            }
          </div>
        </div>
      } @empty { <p class="muted">No hay turnos en los próximos {{ diasVista }} días.</p> }
    </div>
  `,
  styles: `
    .dias { display: flex; flex-wrap: wrap; gap: 10px; }
    .modos { display: flex; flex-wrap: wrap; gap: 18px; margin-bottom: 10px; }
    .modos label { display: flex; gap: 6px; align-items: center; font-weight: normal; }
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
  protected readonly limite = new Date(Date.now() + 90 * 86_400_000).toISOString().slice(0, 10);
  protected modo: 'semana' | 'fechas' = 'semana';
  protected fechaNueva = '';
  protected readonly fechas = signal<string[]>([]);
  protected diasVista = 14;
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
        { dias: this.diasVista, ...(this.auth.tiene('ADMIN') ? { medico_id: this.medicoId } : {}) }));
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
      const dias = this.modo === 'semana'
        ? { desde: this.desde, hasta: this.hasta, dias: [...this.elegidos()].sort() }
        : { fechas: this.fechas() };
      const r = await this.api.post<{ franjas_creadas: number; omitidas: number }>('/api/citas/horario', {
        ...dias, bloques: this.bloques, ...(this.auth.tiene('ADMIN') ? { medico_id: this.medicoId } : {}),
      });
      this.aviso.set(`Se crearon ${r.franjas_creadas} turnos` + (r.omitidas ? ` (${r.omitidas} ya existían o se cruzaban con otros).` : '.'));
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
    } finally {
      this.ocupado.set(false);
    }
  }

  protected diaSemana(f: string) {
    return ['Dom', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb'][new Date(`${f}T12:00:00`).getDay()];
  }

  protected libres(turnos: Turno[]) {
    return turnos.filter((t) => !t.ocupados).length;
  }

  agregarFecha() {
    if (this.fechaNueva && !this.fechas().includes(this.fechaNueva)) this.fechas.update((x) => [...x, this.fechaNueva].sort());
    this.fechaNueva = '';
  }

  quitarFecha(f: string) {
    this.fechas.update((x) => x.filter((y) => y !== f));
  }

  async quitarDia(fecha: string) {
    this.error.set('');
    this.aviso.set('');
    try {
      const r = await this.api.post<{ quitados: number }>('/api/citas/horario/quitar', {
        fechas: [fecha], ...(this.auth.tiene('ADMIN') ? { medico_id: this.medicoId } : {}),
      });
      this.aviso.set(`Se quitaron ${r.quitados} turnos libres del ${fecha}. Puede generar el horario nuevo de ese día con "Fechas sueltas".`);
      this.modo = 'fechas';
      if (!this.fechas().includes(fecha)) this.fechas.update((x) => [...x, fecha].sort());
      await this.cargar();
    } catch (e) {
      this.error.set(mensajeError(e));
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
