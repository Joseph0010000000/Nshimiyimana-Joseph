AKAZILIFE/
├── server.js
├── package.json
├── .env
├── public/
│   ├── index.html
│   ├── style.css
│   └── app.js
└── database/
    └── schema.sql
{
  "name": "akazilife",
  "version": "1.0.0",
  "description": "AKAZILIFE - Connecting workers with employers",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "node server.js"
  },
  "dependencies": {
    "bcryptjs": "^2.4.3",
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.21.0",
    "jsonwebtoken": "^9.0.2",
    "pg": "^8.12.0"
  }
}CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(30),
    password VARCHAR(255) NOT NULL,
    user_type VARCHAR(20) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE jobs (
    id SERIAL PRIMARY KEY,
    employer_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(200) NOT NULL,
    description TEXT NOT NULL,
    location VARCHAR(200),
    salary VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE applications (
    id SERIAL PRIMARY KEY,
    job_id INTEGER REFERENCES jobs(id) ON DELETE CASCADE,
    worker_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    status VARCHAR(30) DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
PORT=3000
DATABASE_URL=your_database_connection_string
JWT_SECRET=change_this_to_a_long_random_secret
const express = require("express");
const cors = require("cors");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const { Pool } = require("pg");
require("dotenv").config();

const app = express();

app.use(cors());
app.use(express.json());
app.use(express.static("public"));

const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: {
        rejectUnauthorized: false
    }
});

// HOME
app.get("/api", (req, res) => {
    res.json({
        message: "Welcome to AKAZILIFE API"
    });
});

// REGISTER
app.post("/api/register", async (req, res) => {
    try {
        const {
            firstName,
            lastName,
            email,
            phone,
            password,
            userType
        } = req.body;

        if (!firstName || !lastName || !email || !password || !userType) {
            return res.status(400).json({
                message: "Please fill in all required fields."
            });
        }

        if (!["worker", "employer"].includes(userType)) {
            return res.status(400).json({
                message: "Invalid account type."
            });
        }

        const existingUser = await pool.query(
            "SELECT id FROM users WHERE email = $1",
            [email]
        );

        if (existingUser.rows.length > 0) {
            return res.status(409).json({
                message: "An account with this email already exists."
            });
        }

        const hashedPassword = await bcrypt.hash(password, 10);

        const result = await pool.query(
            `INSERT INTO users
            (first_name, last_name, email, phone, password, user_type)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING id, first_name, last_name, email, phone, user_type`,
            [
                firstName,
                lastName,
                email,
                phone,
                hashedPassword,
                userType
            ]
        );

        res.status(201).json({
            message: "Account created successfully.",
            user: result.rows[0]
        });

    } catch (error) {
        console.error(error);
        res.status(500).json({
            message: "Server error."
        });
    }
});

// LOGIN
app.post("/api/login", async (req, res) => {
    try {
        const { email, password } = req.body;

        const result = await pool.query(
            "SELECT * FROM users WHERE email = $1",
            [email]
        );

        if (result.rows.length === 0) {
            return res.status(401).json({
                message: "Invalid email or password."
            });
        }

        const user = result.rows[0];

        const passwordCorrect = await bcrypt.compare(
            password,
            user.password
        );

        if (!passwordCorrect) {
            return res.status(401).json({
                message: "Invalid email or password."
            });
        }

        const token = jwt.sign(
            {
                id: user.id,
                userType: user.user_type
            },
            process.env.JWT_SECRET,
            {
                expiresIn: "7d"
            }
        );

        res.json({
            message: "Login successful.",
            token,
            user: {
                id: user.id,
                firstName: user.first_name,
                lastName: user.last_name,
                email: user.email,
                phone: user.phone,
                userType: user.user_type
            }
        });

    } catch (error) {
        console.error(error);
        res.status(500).json({
            message: "Server error."
        });
    }
});

// GET JOBS
app.get("/api/jobs", async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT
                jobs.id,
                jobs.title,
                jobs.description,
                jobs.location,
                jobs.salary,
                jobs.created_at,
                users.first_name,
                users.last_name
            FROM jobs
            JOIN users
            ON jobs.employer_id = users.id
            ORDER BY jobs.created_at DESC
        `);

        res.json(result.rows);

    } catch (error) {
        console.error(error);
        res.status(500).json({
            message: "Could not load jobs."
        });
    }
});

// CREATE JOB
app.post("/api/jobs", async (req, res) => {
    try {
        const {
            employerId,
            title,
            description,
            location,
            salary
        } = req.body;

        if (!employerId || !title || !description) {
            return res.status(400).json({
                message: "Missing required information."
            });
        }

        const employer = await pool.query(
            "SELECT user_type FROM users WHERE id = $1",
            [employerId]
        );

        if (
            employer.rows.length === 0 ||
            employer.rows[0].user_type !== "employer"
        ) {
            return res.status(403).json({
                message: "Only employers can create jobs."
            });
        }

        const result = await pool.query(
            `INSERT INTO jobs
            (employer_id, title, description, location, salary)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING *`,
            [
                employerId,
                title,
                description,
                location,
                salary
            ]
        );

        res.status(201).json({
            message: "Job posted successfully.",
            job: result.rows[0]
        });

    } catch (error) {
        console.error(error);
        res.status(500).json({
            message: "Could not create job."
        });
    }
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
    console.log(`AKAZILIFE running on port ${PORT}`);
});
<!DOCTYPE html>
<html lang="en">

<head>
    <meta charset="UTF-8">
    <meta name="viewport"
          content="width=device-width, initial-scale=1.0">

    <title>AKAZILIFE</title>

    <link rel="stylesheet" href="style.css">
</head>

<body>

<header>
    <div class="logo">AKAZILIFE</div>

    <nav>
        <a href="#home">Home</a>
        <a href="#jobs">Find Jobs</a>
        <a href="#register">Register</a>
        <a href="#login">Login</a>
    </nav>
</header>

<section id="home" class="hero">

    <div>
        <h1>Find Work. Find Workers.</h1>

        <p>
            AKAZILIFE connects people looking for work
            with employers looking for reliable workers.
        </p>

        <div class="buttons">
            <a href="#jobs" class="button">
                Find a Job
            </a>

            <a href="#register" class="button secondary">
                Create Account
            </a>
        </div>
    </div>

</section>

<section id="jobs">

    <h2>Available Jobs</h2>

    <div id="jobList" class="job-container">
        Loading jobs...
    </div>

</section>

<section id="register">

    <h2>Create an AKAZILIFE Account</h2>

    <form id="registerForm">

        <input
            type="text"
            id="firstName"
            placeholder="First Name"
            required
        >

        <input
            type="text"
            id="lastName"
            placeholder="Last Name"
            required
        >

        <input
            type="email"
            id="email"
            placeholder="Email"
            required
        >

        <input
            type="tel"
            id="phone"
            placeholder="Phone Number"
        >

        <input
            type="password"
            id="password"
            placeholder="Password"
            required
        >

        <select id="userType" required>

            <option value="">
                Select account type
            </option>

            <option value="worker">
                I am looking for work
            </option>

            <option value="employer">
                I need workers
            </option>

        </select>

        <button type="submit">
            Create Account
        </button>

    </form>

    <p id="registerMessage"></p>

</section>

<section id="login">

    <h2>Login</h2>

    <form id="loginForm">

        <input
            type="email"
            id="loginEmail"
            placeholder="Email"
            required
        >

        <input
            type="password"
            id="loginPassword"
            placeholder="Password"
            required
        >

        <button type="submit">
            Login
        </button>

    </form>

    <p id="loginMessage"></p>

</section>

<footer>
    <p>© 2026 AKAZILIFE. Connecting people with opportunities.</p>
</footer>

<script src="app.js"></script>

</body>
</html>
* {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
}

body {
    font-family: Arial, sans-serif;
    background: #f5f7fa;
    color: #222;
}

header {
    background: #0b5ed7;
    color: white;
    padding: 18px 7%;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.logo {
    font-size: 25px;
    font-weight: bold;
}

nav a {
    color: white;
    text-decoration: none;
    margin-left: 20px;
}

.hero {
    min-height: 500px;
    display: flex;
    align-items: center;
    padding: 60px 8%;
    background: linear-gradient(
        135deg,
        #0b5ed7,
        #54a0ff
    );
    color: white;
}

.hero h1 {
    font-size: 48px;
    margin-bottom: 20px;
}

.hero p {
    font-size: 20px;
    max-width: 600px;
    line-height: 1.6;
}

.buttons {
    margin-top: 30px;
}

.button {
    display: inline-block;
    padding: 14px 25px;
    background: white;
    color: #0b5ed7;
    text-decoration: none;
    border-radius: 8px;
    margin-right: 10px;
    font-weight: bold;
}

.button.secondary {
    background: #222;
    color: white;
}

section {
    padding: 60px 8%;
}

h2 {
    text-align: center;
    margin-bottom: 30px;
}

form {
    max-width: 500px;
    margin: auto;
    display: flex;
    flex-direction: column;
    gap: 15px;
}

input,
select,
button {
    padding: 14px;
    font-size: 16px;
    border-radius: 7px;
    border: 1px solid #ccc;
}

button {
    background: #0b5ed7;
    color: white;
    border: none;
    cursor: pointer;
    font-weight: bold;
}

button:hover {
    background: #084298;
}

.job-container {
    max-width: 900px;
    margin: auto;
}

.job-card {
    background: white;
    padding: 25px;
    margin-bottom: 20px;
    border-radius: 10px;
    box-shadow: 0 3px 12px rgba(0,0,0,0.08);
}

.job-card h3 {
    color: #0b5ed7;
    margin-bottom: 10px;
}

.job-card p {
    margin: 8px 0;
}

footer {
    background: #222;
    color: white;
    text-align: center;
    padding: 25px;
}

@media (max-width: 700px) {

    header {
        flex-direction: column;
        gap: 15px;
    }

    nav a {
        margin: 5px;
        display: inline-block;
    }

    .hero h1 {
        font-size: 35px;
    }

    .hero p {
        font-size: 17px;
    }
}
const API = "/api";

// REGISTER
document
    .getElementById("registerForm")
    .addEventListener("submit", async function (event) {

        event.preventDefault();

        const data = {
            firstName:
                document.getElementById("firstName").value,

            lastName:
                document.getElementById("lastName").value,

            email:
                document.getElementById("email").value,

            phone:
                document.getElementById("phone").value,

            password:
                document.getElementById("password").value,

            userType:
                document.getElementById("userType").value
        };

        const response = await fetch(
            `${API}/register`,
            {
                method: "POST",
                headers: {
                    "Content-Type": "application/json"
                },
                body: JSON.stringify(data)
            }
        );

        const result = await response.json();

        document.getElementById(
            "registerMessage"
        ).textContent = result.message;

        if (response.ok) {
            document.getElementById(
                "registerForm"
            ).reset();
        }
    });

// LOGIN
document
    .getElementById("loginForm")
    .addEventListener("submit", async function (event) {

        event.preventDefault();

        const data = {
            email:
                document.getElementById("loginEmail").value,

            password:
                document.getElementById("loginPassword").value
        };

        const response = await fetch(
            `${API}/login`,
            {
                method: "POST",
                headers: {
                    "Content-Type": "application/json"
                },
                body: JSON.stringify(data)
            }
        );

        const result = await response.json();

        document.getElementById(
            "loginMessage"
        ).textContent = result.message;

        if (response.ok) {
            localStorage.setItem(
                "akazilife_token",
                result.token
            );

            localStorage.setItem(
                "akazilife_user",
                JSON.stringify(result.user)
            );
        }
    });

// LOAD JOBS
async function loadJobs() {

    try {

        const response = await fetch(
            `${API}/jobs`
        );

        const jobs = await response.json();

        const jobList =
            document.getElementById("jobList");

        if (jobs.length === 0) {
            jobList.innerHTML =
                "<p>No jobs available yet.</p>";

            return;
        }

        jobList.innerHTML = "";

        jobs.forEach(job => {

            const card =
                document.createElement("div");

            card.className = "job-card";

            card.innerHTML = `
                <h3>${job.title}</h3>

                <p>
                    ${job.description}
                </p>

                <p>
                    <strong>Location:</strong>
                    ${job.location || "Not specified"}
                </p>

                <p>
                    <strong>Salary:</strong>
                    ${job.salary || "Negotiable"}
                </p>

                <p>
                    <strong>Employer:</strong>
                    ${job.first_name} ${job.last_name}
                </p>
            `;

            jobList.appendChild(card);
        });

    } catch (error) {

        document.getElementById(
            "jobList"
        ).textContent =
            "Unable to load jobs.";

    }
}

loadJobs();
