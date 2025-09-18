# Backend - FastAPI Application
# File: main.py

from fastapi import FastAPI, HTTPException, UploadFile, File, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from sqlalchemy import create_engine, Column, Integer, String, Float, Boolean, Text, DateTime, ForeignKey
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session, relationship
from pydantic import BaseModel
from typing import List, Optional
import pandas as pd
import openai
import anthropic
import io
import csv
from datetime import datetime
import os
from dotenv import load_dotenv
import json

load_dotenv()

# Database setup
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://user:password@localhost/signrecipes")
engine = create_engine(DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

# Database Models
class Product(Base):
    __tablename__ = "products"
    
    id = Column(Integer, primary_key=True, index=True)
    product_code = Column(String, unique=True, index=True)
    product_name = Column(String, index=True)
    category = Column(String)
    core_capability = Column(Boolean)
    outsourced = Column(Boolean)
    assigned_recipe = Column(String)
    short_description = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)

class Material(Base):
    __tablename__ = "materials"
    
    id = Column(Integer, primary_key=True, index=True)
    partcode = Column(String, unique=True, index=True)
    friendly_description = Column(String)
    base = Column(String)
    sub = Column(String)
    thk = Column(Float)
    grd = Column(String)
    created_at = Column(DateTime, default=datetime.utcnow)

class Process(Base):
    __tablename__ = "processes"
    
    id = Column(Integer, primary_key=True, index=True)
    sort_id = Column(Integer)
    parent_id = Column(Integer)
    proc_code = Column(String, unique=True, index=True)
    proc_name = Column(String)
    discipline = Column(String)
    input_form = Column(String)
    output_form = Column(String)
    key_tools = Column(String)
    setup_time_min = Column(Float)
    run_rate_unit = Column(String)
    defect_risk_percent = Column(Float)
    notes = Column(Text)
    created_at = Column(DateTime, default=datetime.utcnow)

class Recipe(Base):
    __tablename__ = "recipes"
    
    id = Column(Integer, primary_key=True, index=True)
    product_code = Column(String, ForeignKey("products.product_code"))
    product_name = Column(String)
    recipe_section = Column(String)  # 'Material' or 'Process'
    sequence = Column(Integer)
    parent_sequence = Column(Integer, nullable=True)
    process_material_code = Column(String)
    process_name = Column(String)
    work_instruction = Column(Text)
    discipline = Column(String)
    created_at = Column(DateTime, default=datetime.utcnow)
    
    product = relationship("Product", foreign_keys=[product_code])

class ChatSession(Base):
    __tablename__ = "chat_sessions"
    
    id = Column(Integer, primary_key=True, index=True)
    session_id = Column(String, unique=True, index=True)
    user_message = Column(Text)
    ai_response = Column(Text)
    recipe_generated = Column(Boolean, default=False)
    created_at = Column(DateTime, default=datetime.utcnow)

# Create tables
Base.metadata.create_all(bind=engine)

# Pydantic models
class ProductResponse(BaseModel):
    product_code: str
    product_name: str
    category: str
    short_description: Optional[str]

class RecipeItem(BaseModel):
    product_code: str
    product_name: str
    recipe_section: str
    sequence: int
    parent_sequence: Optional[int]
    process_material_code: str
    process_name: str
    work_instruction: str
    discipline: str

class RecipeResponse(BaseModel):
    product: ProductResponse
    recipe: List[RecipeItem]
    total_materials: int
    total_processes: int

class ChatRequest(BaseModel):
    message: str
    session_id: Optional[str] = None

class ChatResponse(BaseModel):
    response: str
    recipe: Optional[RecipeResponse] = None
    session_id: str

# FastAPI app
app = FastAPI(title="Sign Recipe Generator API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000"],  # React frontend
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# AI Clients
openai.api_key = os.getenv("OPENAI_API_KEY")
anthropic_client = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))

# Database dependency
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# AI Recipe Generation Service
class RecipeAIService:
    def __init__(self, db: Session):
        self.db = db
        
    def get_system_prompt(self):
        # Get counts from database
        products_count = self.db.query(Product).count()
        materials_count = self.db.query(Material).count()
        processes_count = self.db.query(Process).count()
        
        return f"""You are an expert MIS Workflow specialist for the sign and print industry. Your mission is to create detailed manufacturing recipes.

Available Data:
- {products_count} products in catalog
- {materials_count} materials in database  
- {processes_count} processes in library

CRITICAL REQUIREMENTS:
1. Always include ADM-STD-ADMIN as the first process
2. Always include packing/dispatch as the last process
3. List materials first, then processes
4. Use proper sequencing (1, 2, 3...)
5. Include parent_sequence for materials used in processes
6. Default workflow: print → laminate → mount (unless flatbed specified)
7. Each material needs corresponding process (e.g., eyelets material + eyeletting process)

OUTPUT FORMAT:
Return a JSON object with:
{{
  "product_match": {{
    "product_code": "PRD-XXXX",
    "product_name": "Product Name",
    "category": "Category",
    "confidence": 0.95
  }},
  "recipe": [
    {{
      "recipe_section": "Material|Process",
      "sequence": 1,
      "parent_sequence": null,
      "process_material_code": "CODE",
      "process_name": "Name",
      "work_instruction": "Detailed instruction",
      "discipline": "Discipline"
    }}
  ]
}}

Available materials include: ACM panels, SAV vinyl, laminates, corrugated boards, adhesives, eyelets, etc.
Available processes include: artwork setup, printing, laminating, mounting, cutting, finishing, etc.

Generate a complete recipe based on the user's product description."""

    async def generate_recipe_openai(self, user_message: str) -> dict:
        """Generate recipe using OpenAI GPT-4"""
        try:
            # Get sample data for context
            products = self.db.query(Product).limit(10).all()
            materials = self.db.query(Material).limit(20).all()
            processes = self.db.query(Process).filter(Process.parent_id == 0).limit(30).all()
            
            context = {
                "sample_products": [{"code": p.product_code, "name": p.product_name, "category": p.category} for p in products],
                "sample_materials": [{"code": m.partcode, "name": m.friendly_description, "base": m.base} for m in materials],
                "sample_processes": [{"code": p.proc_code, "name": p.proc_name, "discipline": p.discipline} for p in processes]
            }
            
            messages = [
                {"role": "system", "content": self.get_system_prompt()},
                {"role": "user", "content": f"Create a manufacturing recipe for: {user_message}\n\nContext: {json.dumps(context, indent=2)}"}
            ]
            
            response = await openai.ChatCompletion.acreate(
                model="gpt-4",
                messages=messages,
                temperature=0.3,
                max_tokens=2000
            )
            
            return json.loads(response.choices[0].message.content)
            
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"OpenAI API error: {str(e)}")

    async def generate_recipe_claude(self, user_message: str) -> dict:
        """Generate recipe using Anthropic Claude"""
        try:
            # Get sample data for context
            products = self.db.query(Product).limit(10).all()
            materials = self.db.query(Material).limit(20).all()
            processes = self.db.query(Process).filter(Process.parent_id == 0).limit(30).all()
            
            context = {
                "sample_products": [{"code": p.product_code, "name": p.product_name, "category": p.category} for p in products],
                "sample_materials": [{"code": m.partcode, "name": m.friendly_description, "base": m.base} for m in materials],
                "sample_processes": [{"code": p.proc_code, "name": p.proc_name, "discipline": p.discipline} for p in processes]
            }
            
            prompt = f"""{self.get_system_prompt()}

Create a manufacturing recipe for: {user_message}

Context: {json.dumps(context, indent=2)}"""

            message = anthropic_client.messages.create(
                model="claude-3-sonnet-20240229",
                max_tokens=2000,
                temperature=0.3,
                messages=[{"role": "user", "content": prompt}]
            )
            
            return json.loads(message.content[0].text)
            
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Claude API error: {str(e)}")

# API Endpoints
@app.post("/api/upload-data")
async def upload_data(
    products_file: UploadFile = File(...),
    materials_file: UploadFile = File(...),
    processes_file: UploadFile = File(...),
    db: Session = Depends(get_db)
):
    """Upload and populate database with CSV data"""
    try:
        # Clear existing data
        db.query(Recipe).delete()
        db.query(Product).delete()
        db.query(Material).delete()
        db.query(Process).delete()
        
        # Load products
        products_df = pd.read_csv(io.StringIO((await products_file.read()).decode('utf-8')))
        for _, row in products_df.iterrows():
            product = Product(
                product_code=row['Product Code'],
                product_name=row['Product Name'],
                category=row['Category'],
                core_capability=row.get('Core Capability', False),
                outsourced=row.get('Outsourced', False),
                assigned_recipe=row.get('Assigned Recipe', ''),
                short_description=row.get('Short Description', '')
            )
            db.add(product)
        
        # Load materials
        materials_df = pd.read_csv(io.StringIO((await materials_file.read()).decode('utf-8')))
        for _, row in materials_df.iterrows():
            material = Material(
                partcode=row['partcode'],
                friendly_description=row['friendly_description'],
                base=row['base'],
                sub=row.get('sub', ''),
                thk=row.get('thk', 0),
                grd=row.get('grd', '')
            )
            db.add(material)
        
        # Load processes
        processes_df = pd.read_csv(io.StringIO((await processes_file.read()).decode('utf-8')))
        for _, row in processes_df.iterrows():
            process = Process(
                sort_id=row.get('sortID', 0),
                parent_id=row.get('parentID', 0),
                proc_code=row['PROC_CODE'],
                proc_name=row['PROC_NAME'],
                discipline=row.get('DISCIPLINE', ''),
                input_form=row.get('INPUT_FORM', ''),
                output_form=row.get('OUTPUT_FORM', ''),
                key_tools=row.get('KEY_TOOLS', ''),
                setup_time_min=row.get('SETUP_TIME_MIN', 0),
                run_rate_unit=row.get('RUN_RATE_UNIT', ''),
                defect_risk_percent=row.get('DEFECT_RISK_%', 0),
                notes=row.get('NOTES', '')
            )
            db.add(process)
        
        db.commit()
        
        return {
            "message": "Data uploaded successfully",
            "products": len(products_df),
            "materials": len(materials_df),
            "processes": len(processes_df)
        }
        
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Upload error: {str(e)}")

@app.post("/api/chat", response_model=ChatResponse)
async def chat_with_ai(
    request: ChatRequest,
    db: Session = Depends(get_db),
    ai_provider: str = "openai"  # or "claude"
):
    """Chat endpoint that generates recipes using AI"""
    try:
        ai_service = RecipeAIService(db)
        
        # Generate recipe using specified AI provider
        if ai_provider == "claude":
            ai_response = await ai_service.generate_recipe_claude(request.message)
        else:
            ai_response = await ai_service.generate_recipe_openai(request.message)
        
        # Save recipe to database
        recipe_items = []
        for item in ai_response["recipe"]:
            recipe = Recipe(
                product_code=ai_response["product_match"]["product_code"],
                product_name=ai_response["product_match"]["product_name"],
                recipe_section=item["recipe_section"],
                sequence=item["sequence"],
                parent_sequence=item.get("parent_sequence"),
                process_material_code=item["process_material_code"],
                process_name=item["process_name"],
                work_instruction=item["work_instruction"],
                discipline=item["discipline"]
            )
            db.add(recipe)
            recipe_items.append(RecipeItem(**item))
        
        db.commit()
        
        # Create response
        product_response = ProductResponse(
            product_code=ai_response["product_match"]["product_code"],
            product_name=ai_response["product_match"]["product_name"],
            category=ai_response["product_match"]["category"],
            short_description=""
        )
        
        recipe_response = RecipeResponse(
            product=product_response,
            recipe=recipe_items,
            total_materials=len([r for r in recipe_items if r.recipe_section == "Material"]),
            total_processes=len([r for r in recipe_items if r.recipe_section == "Process"])
        )
        
        # Save chat session
        session = ChatSession(
            session_id=request.session_id or f"session_{datetime.now().isoformat()}",
            user_message=request.message,
            ai_response=f"Generated recipe for {product_response.product_name}",
            recipe_generated=True
        )
        db.add(session)
        db.commit()
        
        return ChatResponse(
            response=f"I've generated a complete manufacturing recipe for **{product_response.product_name}**. The recipe includes {recipe_response.total_materials} materials and {recipe_response.total_processes} processes, following industry best practices.",
            recipe=recipe_response,
            session_id=session.session_id
        )
        
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Chat error: {str(e)}")

@app.get("/api/recipe/{product_code}/download")
async def download_recipe(product_code: str, db: Session = Depends(get_db)):
    """Download recipe as CSV"""
    try:
        recipes = db.query(Recipe).filter(Recipe.product_code == product_code).order_by(Recipe.sequence).all()
        
        if not recipes:
            raise HTTPException(status_code=404, detail="Recipe not found")
        
        # Create CSV data
        csv_data = []
        for recipe in recipes:
            csv_data.append({
                "Product Code": recipe.product_code,
                "Product Name": recipe.product_name,
                "Recipe Section": recipe.recipe_section,
                "Sequence": recipe.sequence,
                "Parent Sequence": recipe.parent_sequence or "",
                "Process/Material Code": recipe.process_material_code,
                "Process Name": recipe.process_name,
                "Work Instruction": recipe.work_instruction,
                "Discipline": recipe.discipline
            })
        
        # Generate CSV
        output = io.StringIO()
        writer = csv.DictWriter(output, fieldnames=csv_data[0].keys())
        writer.writeheader()
        writer.writerows(csv_data)
        
        # Return as download
        output.seek(0)
        filename = f"{recipes[0].product_name.replace(' ', '_')}_recipe.csv"
        
        return StreamingResponse(
            io.BytesIO(output.getvalue().encode('utf-8')),
            media_type="text/csv",
            headers={"Content-Disposition": f"attachment; filename={filename}"}
        )
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Download error: {str(e)}")

@app.get("/api/products")
async def get_products(db: Session = Depends(get_db)):
    """Get all products"""
    products = db.query(Product).all()
    return [ProductResponse(
        product_code=p.product_code,
        product_name=p.product_name,
        category=p.category,
        short_description=p.short_description
    ) for p in products]

@app.get("/api/stats")
async def get_stats(db: Session = Depends(get_db)):
    """Get database statistics"""
    return {
        "products": db.query(Product).count(),
        "materials": db.query(Material).count(),
        "processes": db.query(Process).count(),
        "recipes": db.query(Recipe).count(),
        "chat_sessions": db.query(ChatSession).count()
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
