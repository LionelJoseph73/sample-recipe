// Frontend - React Application
// File: src/App.js

import React, { useState, useEffect } from 'react';
import { 
  Upload, 
  MessageSquare, 
  Download, 
  FileText, 
  Database,
  Settings,
  BarChart3,
  Loader2,
  CheckCircle,
  AlertCircle
} from 'lucide-react';
import './App.css';

const API_BASE_URL = process.env.REACT_APP_API_URL || 'http://localhost:8000';

function App() {
  const [currentView, setCurrentView] = useState('chat');
  const [messages, setMessages] = useState([]);
  const [currentMessage, setCurrentMessage] = useState('');
  const [isLoading, setIsLoading] = useState(false);
  const [stats, setStats] = useState({});
  const [aiProvider, setAiProvider] = useState('openai');
  const [sessionId, setSessionId] = useState('');
  const [uploadStatus, setUploadStatus] = useState({ status: '', message: '' });

  useEffect(() => {
    loadStats();
    setSessionId(`session_${Date.now()}`);
  }, []);

  const loadStats = async () => {
    try {
      const response = await fetch(`${API_BASE_URL}/api/stats`);
      const data = await response.json();
      setStats(data);
    } catch (error) {
      console.error('Error loading stats:', error);
    }
  };

  const handleFileUpload = async (files) => {
    if (files.length !== 3) {
      setUploadStatus({ status: 'error', message: 'Please upload all 3 files: Products, Materials, and Processes CSV files' });
      return;
    }

    setIsLoading(true);
    setUploadStatus({ status: 'loading', message: 'Uploading and processing files...' });

    try {
      const formData = new FormData();
      formData.append('products_file', files[0]);
      formData.append('materials_file', files[1]);
      formData.append('processes_file', files[2]);

      const response = await fetch(`${API_BASE_URL}/api/upload-data`, {
        method: 'POST',
        body: formData,
      });

      if (!response.ok) {
        throw new Error('Upload failed');
      }

      const data = await response.json();
      setUploadStatus({ 
        status: 'success', 
        message: `Successfully uploaded ${data.products} products, ${data.materials} materials, and ${data.processes} processes` 
      });
      
      loadStats();
      
      // Add welcome message
      setMessages([{
        type: 'system',
        content: `Data successfully loaded! Ready to generate manufacturing recipes using ${aiProvider.toUpperCase()} AI.`,
        timestamp: new Date()
      }]);

    } catch (error) {
      setUploadStatus({ status: 'error', message: 'Upload failed. Please try again.' });
    } finally {
      setIsLoading(false);
    }
  };

  const sendMessage = async () => {
    if (!currentMessage.trim() || isLoading) return;

    const userMessage = {
      type: 'user',
      content: currentMessage,
      timestamp: new Date()
    };

    setMessages(prev => [...prev, userMessage]);
    setIsLoading(true);

    try {
      const response = await fetch(`${API_BASE_URL}/api/chat?ai_provider=${aiProvider}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: currentMessage,
          session_id: sessionId
        }),
      });

      if (!response.ok) {
        throw new Error('API request failed');
      }

      const data = await response.json();
      
      const assistantMessage = {
        type: 'assistant',
        content: data.response,
        recipe: data.recipe,
        timestamp: new Date()
      };

      setMessages(prev => [...prev, assistantMessage]);
      loadStats();

    } catch (error) {
      const errorMessage = {
        type: 'error',
        content: 'Sorry, there was an error generating the recipe. Please try again.',
        timestamp: new Date()
      };
      setMessages(prev => [...prev, errorMessage]);
    } finally {
      setIsLoading(false);
    }

    setCurrentMessage('');
  };

  const downloadRecipe = async (productCode, productName) => {
    try {
      const response = await fetch(`${API_BASE_URL}/api/recipe/${productCode}/download`);
      
      if (!response.ok) {
        throw new Error('Download failed');
      }

      const blob = await response.blob();
      const url = window.URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${productName.replace(/[^a-z0-9]/gi, '_')}_recipe.csv`;
      document.body.appendChild(a);
      a.click();
      window.URL.revokeObjectURL(url);
      document.body.removeChild(a);
    } catch (error) {
      alert('Download failed. Please try again.');
    }
  };

  const RecipeTable = ({ recipe }) => (
    <div className="recipe-table-container">
      <div className="recipe-header">
        <div className="recipe-title">
          <FileText size={18} />
          <span>Manufacturing Recipe</span>
        </div>
        <button
          onClick={() => downloadRecipe(recipe.product.product_code, recipe.product.product_name)}
          className="download-btn"
        >
          <Download size={16} />
          Download CSV
        </button>
      </div>
      
      <div className="recipe-summary">
        <div className="summary-item">
          <span className="summary-label">Product:</span>
          <span className="summary-value">{recipe.product.product_name} ({recipe.product.product_code})</span>
        </div>
        <div className="summary-stats">
          <span className="stat-item materials">{recipe.total_materials} Materials</span>
          <span className="stat-item processes">{recipe.total_processes} Processes</span>
        </div>
      </div>

      <div className="table-wrapper">
        <table className="recipe-table">
          <thead>
            <tr>
              <th>Seq</th>
              <th>Section</th>
              <th>Code</th>
              <th>Process/Material Name</th>
              <th>Work Instruction</th>
              <th>Discipline</th>
              <th>Parent</th>
            </tr>
          </thead>
          <tbody>
            {recipe.recipe.map((item, index) => (
              <tr key={index} className={`row-${item.recipe_section.toLowerCase()}`}>
                <td className="seq-cell">{item.sequence}</td>
                <td>
                  <span className={`section-badge ${item.recipe_section.toLowerCase()}`}>
                    {item.recipe_section}
                  </span>
                </td>
                <td className="code-cell">{item.process_material_code}</td>
                <td className="name-cell">{item.process_name}</td>
                <td className="instruction-cell">{item.work_instruction}</td>
                <td className="discipline-cell">{item.discipline}</td>
                <td className="parent-cell">{item.parent_sequence || '-'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      
      <div className="recipe-footer">
        Ready for M-Power MIS import • Generated using {aiProvider.toUpperCase()} AI
      </div>
    </div>
  );

  const FileUploadArea = () => (
    <div className="upload-section">
      <h3>Data Upload</h3>
      <p>Upload your 3 CSV files to populate the database:</p>
      
      <div className="upload-area">
        <input
          type="file"
          multiple
          accept=".csv"
          onChange={(e) => handleFileUpload(Array.from(e.target.files))}
          id="file-upload"
          className="file-input"
        />
        <label htmlFor="file-upload" className="upload-label">
          <Upload size={24} />
          <span>Choose CSV Files</span>
          <small>Products, Materials, Processes (3 files required)</small>
        </label>
      </div>

      {uploadStatus.status && (
        <div className={`upload-status ${uploadStatus.status}`}>
          {uploadStatus.status === 'loading' && <Loader2 className="spin" size={16} />}
          {uploadStatus.status === 'success' && <CheckCircle size={16} />}
          {uploadStatus.status === 'error' && <AlertCircle size={16} />}
          <span>{uploadStatus.message}</span>
        </div>
      )}
    </div>
  );

  const StatsPanel = () => (
    <div className="stats-panel">
      <h3>Database Statistics</h3>
      <div className="stats-grid">
        <div className="stat-card">
          <div className="stat-number">{stats.products || 0}</div>
          <div className="stat-label">Products</div>
        </div>
        <div className="stat-card">
          <div className="stat-number">{stats.materials || 0}</div>
          <div className="stat-label">Materials</div>
        </div>
        <div className="stat-card">
          <div className="stat-number">{stats.processes || 0}</div>
          <div className="stat-label">Processes</div>
        </div>
        <div className="stat-card">
          <div className="stat-number">{stats.recipes || 0}</div>
          <div className="stat-label">Recipes</div>
        </div>
      </div>
    </div>
  );

  const SettingsPanel = () => (
    <div className="settings-panel">
      <h3>AI Settings</h3>
      <div className="setting-item">
        <label>AI Provider:</label>
        <select 
          value={aiProvider} 
          onChange={(e) => setAiProvider(e.target.value)}
          className="ai-select"
        >
          <option value="openai">OpenAI GPT-4</option>
          <option value="claude">Anthropic Claude</option>
        </select>
      </div>
      <p className="setting-description">
        Choose between OpenAI GPT-4 or Anthropic Claude for natural language understanding and recipe generation.
      </p>
    </div>
  );

  return (
    <div className="app">
      <header className="app-header">
        <div className="header-content">
          <div className="header-title">
            <FileText size={32} />
            <div>
              <h1>Sign Manufacturing Recipe Generator</h1>
              <p>AI-powered workflow creation for the sign and print industry</p>
            </div>
          </div>
          
          <nav className="header-nav">
            <button 
              className={`nav-btn ${currentView === 'chat' ? 'active' : ''}`}
              onClick={() => setCurrentView('chat')}
            >
              <MessageSquare size={18} />
              Chat
            </button>
            <button 
              className={`nav-btn ${currentView === 'upload' ? 'active' : ''}`}
              onClick={() => setCurrentView('upload')}
            >
              <Database size={18} />
              Data
            </button>
            <button 
              className={`nav-btn ${currentView === 'stats' ? 'active' : ''}`}
              onClick={() => setCurrentView('stats')}
            >
              <BarChart3 size={18} />
              Stats
            </button>
            <button 
              className={`nav-btn ${currentView === 'settings' ? 'active' : ''}`}
              onClick={() => setCurrentView('settings')}
            >
              <Settings size={18} />
              Settings
            </button>
          </nav>
        </div>
      </header>

      <main className="app-main">
        {currentView === 'chat' && (
          <div className="chat-container">
            <div className="chat-messages">
              {messages.length === 0 && (
                <div className="welcome-message">
                  <FileText size={48} />
                  <h3>Welcome to AI Recipe Generator</h3>
                  <p>Describe any sign product and I'll generate a complete manufacturing recipe using {aiProvider.toUpperCase()} AI.</p>
                  <div className="example-queries">
                    <h4>Try these examples:</h4>
                    <ul>
                      <li>"ACM panel sign for outdoor use"</li>
                      <li>"Vinyl banner 2m x 1m with eyelets"</li>
                      <li>"Illuminated lightbox sign"</li>
                      <li>"Corflute yard sign with H-frame"</li>
                    </ul>
                  </div>
                </div>
              )}

              {messages.map((message, index) => (
                <div key={index} className={`message ${message.type}`}>
                  <div className="message-content">
                    <div className="message-text">{message.content}</div>
                    
                    {message.recipe && (
                      <RecipeTable recipe={message.recipe} />
                    )}
                    
                    <div className="message-time">
                      {message.timestamp.toLocaleTimeString()}
                    </div>
                  </div>
                </div>
              ))}

              {isLoading && (
                <div className="message assistant">
                  <div className="message-content">
                    <div className="loading-indicator">
                      <Loader2 className="spin" size={16} />
                      <span>Generating recipe using {aiProvider.toUpperCase()}...</span>
                    </div>
                  </div>
                </div>
              )}
            </div>

            <div className="chat-input">
              <div className="input-wrapper">
                <input
                  type="text"
                  value={currentMessage}
                  onChange={(e) => setCurrentMessage(e.target.value)}
                  onKeyPress={(e) => e.key === 'Enter' && sendMessage()}
                  placeholder="Describe the sign product you need a recipe for..."
                  disabled={isLoading}
                  className="message-input"
                />
                <button
                  onClick={sendMessage}
                  disabled={isLoading || !currentMessage.trim()}
                  className="send-button"
                >
                  <MessageSquare size={18} />
                  Generate Recipe
                </button>
              </div>
              
              <div className="input-footer">
                <span className="ai-indicator">
                  Powered by {aiProvider.toUpperCase()} • {stats.products || 0} products, {stats.materials || 0} materials, {stats.processes || 0} processes loaded
                </span>
              </div>
            </div>
          </div>
        )}

        {currentView === 'upload' && <FileUploadArea />}
        {currentView === 'stats' && <StatsPanel />}
        {currentView === 'settings' && <SettingsPanel />}
      </main>
    </div>
  );
}

export default App;
