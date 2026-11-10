from datetime import date, datetime
from decimal import Decimal
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=160)]
Positive = Annotated[Decimal, Field(gt=0, max_digits=18, decimal_places=6, allow_inf_nan=False)]
NonNegative = Annotated[Decimal, Field(ge=0, max_digits=18, decimal_places=6, allow_inf_nan=False)]
Money = Annotated[int, Field(strict=True, ge=0, le=1_000_000_000_000)]
Role = Literal['administrator', 'owner', 'manager', 'employee', 'consultant']


class Body(BaseModel):
    model_config = ConfigDict(extra='forbid')


class ClientBody(Body):
    id: UUID
    name: Name


class InlinePlot(ClientBody):
    area_ha: Positive | None = None
    notes: str = Field(default='', max_length=2000)


class PropertyBody(ClientBody):
    client_id: UUID | None = None
    responsible_user_id: str | None = Field(default=None, min_length=1, max_length=160)
    plots: list[InlinePlot] = Field(default_factory=list, max_length=100)
    area_ha: Positive | None = None
    location: str = Field(default='', max_length=500)
    notes: str = Field(default='', max_length=2000)
    share_with_operators: bool = Field(default=False, strict=True)


class PlotBody(ClientBody):
    property_id: UUID
    area_ha: Positive | None = None
    notes: str = Field(default='', max_length=2000)


class PropertyUpdateBody(Body):
    id: UUID
    expected_version: int = Field(strict=True, ge=1)
    name: Name
    area_ha: Positive | None
    location: str = Field(max_length=500)
    notes: str = Field(max_length=2000)
    archived: bool = Field(strict=True)
    responsible_user_id: str | None = Field(default=None, min_length=1, max_length=160)


class PlotUpdateBody(Body):
    id: UUID
    expected_version: int = Field(strict=True, ge=1)
    name: Name
    area_ha: Positive | None
    notes: str = Field(max_length=2000)
    archived: bool = Field(strict=True)


class CropBody(ClientBody):
    kind: Literal['coffee', 'grain', 'other']


class CycleBody(ClientBody):
    plot_id: UUID
    crop_id: UUID
    area_ha: Positive | None = None
    starts_on: date
    ends_on: date | None = None

    @model_validator(mode='after')
    def dates(self):
        if self.ends_on and self.ends_on < self.starts_on:
            raise ValueError('A data final deve ser igual ou posterior à inicial.')
        return self


class GrantBody(Body):
    user_id: str = Field(min_length=1, max_length=160)
    role: Role | None


class MachineBody(ClientBody):
    hour_meter: NonNegative
    # This pilot's rate excludes fuel and labor; a combined rate is not accepted.
    hourly_cost_cents: Money | None = None
    property_ids: list[UUID] = Field(min_length=1, max_length=100)


class InputBody(ClientBody):
    unit: Literal['kg', 'L', 'un']
    category: str = Field(default='', max_length=160)
    product_type: str = Field(default='', max_length=160)
    notes: str = Field(default='', max_length=2000)


class InputUpdateBody(ClientBody):
    category: str = Field(max_length=160)
    product_type: str = Field(max_length=160)
    expected_name: Name
    expected_category: str = Field(max_length=160)
    expected_product_type: str = Field(max_length=160)


class ReceiptBody(Body):
    id: UUID
    input_id: UUID
    kind: Literal['opening', 'receipt']
    quantity: NonNegative
    value_cents: Money | None = None
    occurred_on: date

    @model_validator(mode='after')
    def amount(self):
        if self.quantity == 0 and self.value_cents not in (0, None):
            raise ValueError('Um saldo físico zero não pode ter valor positivo.')
        if self.kind == 'receipt' and self.quantity == 0:
            raise ValueError('Uma entrada deve ter quantidade positiva.')
        return self


class MachineUse(Body):
    machine_id: UUID
    start_meter: NonNegative
    end_meter: NonNegative

    @model_validator(mode='after')
    def meters(self):
        if self.end_meter < self.start_meter:
            raise ValueError('Horímetro final menor que o inicial.')
        return self


class InputUse(Body):
    input_id: UUID
    quantity: Positive


class RefuelingBody(Body):
    id: UUID
    machine_id: UUID
    source: Literal['stock', 'external']
    input_id: UUID | None = None
    liters: Positive
    hour_meter: NonNegative
    unit_price_cents: Money | None = None
    fuel_name: Name = 'Diesel'
    location: str = Field(default='', max_length=500)

    @model_validator(mode='after')
    def source_fields(self):
        if self.source == 'stock' and (self.input_id is None or self.unit_price_cents is not None):
            raise ValueError('Selecione o combustível do estoque; seu custo é calculado pelo servidor.')
        if self.source == 'external' and self.input_id is not None:
            raise ValueError('Compra em posto não baixa combustível do estoque da propriedade.')
        if self.unit_price_cents is not None and self.liters * self.unit_price_cents > 1_000_000_000_000:
            raise ValueError('Valor do abastecimento acima do limite permitido.')
        return self


class HarvestOutput(Body):
    quantity: NonNegative
    unit: Literal['kg','t','saca','caixa']
    kg_per_unit: Positive | None = None

    @model_validator(mode='after')
    def weight(self):
        if self.unit in ('kg','t') and self.kg_per_unit is not None:
            raise ValueError('Peso por unidade aplica-se somente a sacas e caixas.')
        return self


class OperationBody(Body):
    id: UUID
    cycle_id: UUID
    kind: Literal['planting', 'application', 'management', 'harvest', 'transport', 'other']
    performed_on: date
    area_ha: Positive | None = None
    labor_hours: NonNegative | None = None
    notes: str = Field(default='', max_length=2000)
    machines: list[MachineUse] = Field(default_factory=list, max_length=20)
    inputs: list[InputUse] = Field(default_factory=list, max_length=100)
    refuelings: list[RefuelingBody] = Field(default_factory=list, max_length=20)
    task_id: UUID | None = None
    task_expected_version: int | None = Field(default=None,strict=True,ge=1)
    started_at: datetime | None = None
    ended_at: datetime | None = None
    consumed_fuel_liters: NonNegative | None = None
    labor_cost_cents: Money | None = None
    plan_id: UUID | None = None
    plan_expected_version: int | None = Field(default=None, strict=True, ge=1)
    coverage_total_ha: NonNegative | None = None
    harvest_output: HarvestOutput | None = None
    implement_ids: list[UUID] = Field(default_factory=list, max_length=20)

    @model_validator(mode='after')
    def measurements(self):
        if self.harvest_output is not None and self.kind != 'harvest':
            raise ValueError('Produção colhida aplica-se somente à colheita.')
        for value in (self.started_at, self.ended_at):
            if value is not None and value.tzinfo is None:
                raise ValueError('Informe horários com fuso horário.')
        if self.started_at and self.ended_at and self.ended_at < self.started_at:
            raise ValueError('O término não pode ser anterior ao início.')
        if any(v is not None for v in (self.plan_id, self.plan_expected_version, self.coverage_total_ha)) and any(v is None for v in (self.plan_id, self.plan_expected_version, self.coverage_total_ha)):
            raise ValueError('Informe programação, versão e área única acumulada juntas.')
        return self

    @model_validator(mode='after')
    def task_version(self):
        if (self.task_id is None)!=(self.task_expected_version is None):
            raise ValueError('Informe a tarefa e a versão juntas.')
        return self

    @model_validator(mode='after')
    def no_duplicate_machine(self):
        if len(set(self.implement_ids)) != len(self.implement_ids):
            raise ValueError('Não repita o mesmo implemento.')
        ids = [item.machine_id for item in self.machines]
        if len(ids) != len(set(ids)):
            raise ValueError('Uma máquina não pode aparecer duas vezes na mesma operação.')
        ids = [item.id for item in self.refuelings]
        if len(ids) != len(set(ids)):
            raise ValueError('Um abastecimento não pode aparecer duas vezes.')
        pairs = [(item.machine_id, item.source, item.input_id if item.source == 'stock' else item.fuel_name.casefold()) for item in self.refuelings]
        if len(pairs) != len(set(pairs)):
            raise ValueError('Agrupe o mesmo combustível da mesma máquina em uma linha de abastecimento.')
        if {item.input_id for item in self.inputs} & {item.input_id for item in self.refuelings if item.source == 'stock'}:
            raise ValueError('Não repita o combustível abastecido na lista de insumos consumidos.')
        return self


class StockCorrectionBody(Body):
    id: UUID
    input_id: UUID
    quantity: NonNegative
    value_cents: Money | None = None
    occurred_on: date
    expected_movement_id: UUID
    reason: Name

    @model_validator(mode='after')
    def zero_value(self):
        if self.quantity == 0 and self.value_cents not in (0, None):
            raise ValueError('Saldo físico zero não pode ter valor positivo.')
        return self


class VoidBody(Body):
    id: UUID
    reason: Name
    occurred_on: date


class MachineUpdateBody(Body):
    id: UUID
    name: Name
    hourly_cost_cents: Money | None
    expected_name: Name
    expected_hour_meter: NonNegative
    expected_hourly_cost_cents: Money | None
    expected_property_ids: list[UUID] = Field(min_length=1, max_length=100)
    property_ids: list[UUID] = Field(min_length=1, max_length=100)
