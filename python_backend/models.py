from pydantic import BaseModel, Field
from typing import Optional, Dict, Any, List

class RegionBounds(BaseModel):
    south: float
    north: float
    west: float
    east: float

class RenderRequest(BaseModel):
    region: RegionBounds
    vertical_exaggeration: Optional[float] = 2.5
    azimuth: Optional[float] = 315.0
    altitude: Optional[float] = 45.0
    title: Optional[str] = "Custom Mars Region"

class StatusResponse(BaseModel):
    status: str
    dataset: Optional[str] = None
    xml: Optional[str] = None
    resolution_ppd: Optional[float] = None
    bounds: Optional[Dict[str, float]] = None
    shape: Optional[List[int]] = None
    message: Optional[str] = None