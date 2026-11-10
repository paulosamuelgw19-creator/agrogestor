from datetime import date
from uuid import UUID
from typing import Literal
from pydantic import Field, model_validator,ConfigDict
from .v2_models import Body as BaseBody, Positive, NonNegative, Money, InputUse

class Body(BaseBody):
    model_config=ConfigDict(extra='forbid',str_strip_whitespace=True)

Priority = Literal['low','normal','high','urgent']
Status = Literal['reported','analysis','in_progress','waiting_parts','testing','completed','cancelled']

class TaskBody(Body):
    id: UUID
    cycle_id: UUID
    assignee_id: str = Field(min_length=1,max_length=160)
    title: str = Field(min_length=1,max_length=160)
    kind: Literal['planting','application','management','harvest','transport','other']
    due_on: date
    priority: Priority = 'normal'
    machine_id: UUID | None = None
    planned_area_ha: Positive | None = None
    planned_hours: NonNegative | None = None
    planned_cost_cents: Money | None = None
    planned_inputs: list[InputUse] = Field(default_factory=list,max_length=100)
    notes: str = Field(default='',max_length=2000)

class TaskProgress(Body):
    id: UUID
    expected_version: int = Field(strict=True,ge=1)
    status: Literal['in_progress','blocked','cancelled']
    description: str = Field(min_length=1,max_length=2000)

class OrderBody(Body):
    id: UUID
    property_id: UUID
    machine_id: UUID
    title: str = Field(min_length=1,max_length=160)
    description: str = Field(min_length=1,max_length=2000)
    priority: Priority = 'normal'
    mechanic_id: str | None = Field(default=None,min_length=1,max_length=160)
    due_on: date | None = None
    stop_machine: bool = Field(default=True,strict=True)

class OrderAssign(Body):
    id: UUID
    expected_version: int = Field(strict=True,ge=1)
    mechanic_id: str = Field(min_length=1,max_length=160)
    priority: Priority
    due_on: date | None = None

class ProgressBody(Body):
    id: UUID
    expected_version: int = Field(strict=True,ge=1)
    description: str = Field(min_length=1,max_length=4000)
    status: Status
    machine_released: bool | None = Field(default=None,strict=True)
    labor_hours: NonNegative | None = None
    labor_cost_cents: Money | None = None
    service_cost_cents: Money | None = None
    parts: list[InputUse] = Field(default_factory=list,max_length=100)
    photos: list[UUID] = Field(default_factory=list,max_length=5)
    next_due_on: date | None = None
    next_due_meter: NonNegative | None = None
    @model_validator(mode='after')
    def completion(self):
        if self.status=='completed' and self.machine_released is None:
            raise ValueError('Ao concluir, informe se a máquina está liberada.')
        if self.status!='completed' and self.machine_released is True:
            raise ValueError('Só libere a máquina após concluir e conferir.')
        if self.status in ('reported','cancelled') and (self.parts or self.labor_hours is not None or self.labor_cost_cents is not None or self.service_cost_cents is not None):
            raise ValueError('Custos e peças exigem manutenção em andamento.')
        return self

class ReserveBody(Body):
    id: UUID
    expected_version: int = Field(strict=True,ge=1)
    input_id: UUID
    quantity: NonNegative

class ChecklistItem(Body):
    label: str = Field(min_length=1,max_length=120)
    ok: bool = Field(strict=True)

class ChecklistBody(Body):
    id: UUID
    property_id: UUID
    machine_id: UUID
    phase: Literal['before','after']
    items: list[ChecklistItem] = Field(min_length=1,max_length=30)
    notes: str = Field(default='',max_length=2000)

class LimitBody(Body):
    id: UUID
    property_id: UUID
    input_id: UUID
    minimum_quantity: NonNegative
