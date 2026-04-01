const express = require('express');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Set up the internal workspace path
const WORKSPACE_DIR = '/app/evaluate';

app.post('/submit', async (req, res) => {
    const { username, code, repoOwner, repoName, level: reqLevel } = req.body;
    let level = parseInt(reqLevel) || 1;
    
    if (!username || !code) {
        return res.status(400).send("STATUS=FAILURE\nMESSAGE=Missing username or code");
    }

    // Write the player's code to the internal foundry source folder
    const playerCodePath = path.join(WORKSPACE_DIR, 'src', `Level${level}.sol`);
    fs.writeFileSync(playerCodePath, code);

    console.log(`Evaluating Level ${level} submission from Pilot: ${username} ...`);

    try {
        const secretTestFile = path.join(__dirname, 'levels_vault', `Level${level}`, `Level${level}_secret.t.sol`);
        if (!fs.existsSync(secretTestFile)) {
             throw new Error(`Mission Level ${level} is currently classified. Tests not found.`);
        }
        
        fs.copyFileSync(secretTestFile, path.join(WORKSPACE_DIR, 'test', `Level${level}_secret.t.sol`));

        // Run forge test explicitly pointing to the downloaded secret test
        const output = execSync(`forge test --match-path "test/Level${level}_secret.t.sol" -vv`, {
            cwd: WORKSPACE_DIR,
            encoding: 'utf-8',
            stdio: 'pipe'
        });
        
        if (output.includes("No tests found to run") || output.includes("Ran 0 test suites")) {
             throw new Error("Central Judge Misconfiguration: Secret tests didn't run. Please verify vault paths.");
        }
        
        console.log(`[PASS] ${username} successfully cleared Level ${level}!`);

        // Update Github if token and repo is provided (Leaderboard & Drop file push)
        const GITHUB_TOKEN = process.env.MASTER_PAT;
        if (GITHUB_TOKEN && repoOwner && repoName) {
             console.log("Updating Main Repository...");
             try {
                 // Update Leaderboard in README.md
                 try {
                     const readmeResp = await fetch(`https://api.github.com/repos/${repoOwner}/${repoName}/contents/README.md`, {
                         headers: { 'Authorization': `token ${GITHUB_TOKEN}` }
                     });
                     
                     if (readmeResp.ok) {
                         const readmeData = await readmeResp.json();
                         let readmeContent = Buffer.from(readmeData.content, 'base64').toString('utf8');
                         
                         const headerMatch = readmeContent.match(/<!-- LEADERBOARD_START -->\n(?:\|.*\|\n)?(?:\|.*\|\n)?/);
                         if (headerMatch) {
                             const tableStartData = readmeContent.substring(0, headerMatch.index + headerMatch[0].length);
                             let tableEndIndex = readmeContent.indexOf('<!-- LEADERBOARD_END -->');
                             let remainingReadme = readmeContent.substring(tableEndIndex);
                             
                             let rowsText = readmeContent.substring(headerMatch.index + headerMatch[0].length, tableEndIndex).trim();
                             let rows = rowsText ? rowsText.split('\n') : [];
                             
                             let playerFound = false;
                             let parsedRows = rows.map(r => {
                                 let cols = r.split('|').filter(c => c.trim() !== '');
                                 if (cols.length >= 4) {
                                     let pilot = cols[1].trim();
                                     let highestLevel = parseInt(cols[2].trim()) || 1;
                                     let timeStr = cols[3].trim();
                                     if (pilot === username) {
                                         playerFound = true;
                                         highestLevel = Math.max(highestLevel, level);
                                         timeStr = new Date().toISOString().replace('T', ' ').substring(0, 19);
                                     }
                                     return { pilot, level: highestLevel, timeStr };
                                 }
                                 return null;
                             }).filter(r => r !== null);
                             
                             if (!playerFound) {
                                 parsedRows.push({ pilot: username, level: level, timeStr: new Date().toISOString().replace('T', ' ').substring(0, 19) });
                             }
                             
                             // Sort descending by level, then ascending by time
                             parsedRows.sort((a, b) => {
                                 if (a.level !== b.level) return b.level - a.level;
                                 return new Date(a.timeStr) - new Date(b.timeStr);
                             });
                             
                             let newRowsText = parsedRows.map((r, i) => `| ${i+1} | ${r.pilot} | ${r.level} | ${r.timeStr} |`).join('\n');
                             
                             let newReadmeContent = tableStartData + newRowsText + '\n' + remainingReadme;
                             
                             if (newReadmeContent !== readmeContent) {
                                 await fetch(`https://api.github.com/repos/${repoOwner}/${repoName}/contents/README.md`, {
                                     method: 'PUT',
                                     headers: { 
                                         'Authorization': `token ${GITHUB_TOKEN}`, 
                                         'Content-Type': 'application/json'
                                     },
                                     body: JSON.stringify({
                                         message: `🏆 Update leaderboard for ${username} (Level ${level})`,
                                         content: Buffer.from(newReadmeContent).toString('base64'),
                                         sha: readmeData.sha
                                     })
                                 });
                                 console.log("Leaderboard updated!");
                             }
                         }
                     }
                 } catch (lErr) {
                     console.error("Leaderboard update failed", lErr);
                 }
             } catch (gitErr) {
                 console.error("Github Publish failed", gitErr);
             }
        }
        
        // Build dynamic payload response securely without Gists
        let responsePayload = `STATUS=SUCCESS\nMESSAGE=ACCESS GRANTED! You have passed the hidden evaluation.\n`;
        const nextLevel = level + 1;
        const nextLevelDir = path.join(__dirname, 'levels_vault', `Level${nextLevel}`);
        
        if (fs.existsSync(nextLevelDir)) {
             if (fs.existsSync(path.join(nextLevelDir, `Level${nextLevel}.sol`))) {
                 responsePayload += `FILE_src@Level${nextLevel}.sol=${fs.readFileSync(path.join(nextLevelDir, `Level${nextLevel}.sol`)).toString('base64')}\n`;
             }
             if (fs.existsSync(path.join(nextLevelDir, `Level${nextLevel}_local.t.sol`))) {
                 responsePayload += `FILE_test@Level${nextLevel}.t.sol=${fs.readFileSync(path.join(nextLevelDir, `Level${nextLevel}_local.t.sol`)).toString('base64')}\n`;
             }
             if (fs.existsSync(path.join(nextLevelDir, 'instructions.md'))) {
                 responsePayload += `FILE_instructions@Level${nextLevel}.md=${fs.readFileSync(path.join(nextLevelDir, 'instructions.md')).toString('base64')}\n`;
             }
        }
        
        return res.status(200).send(responsePayload);

    } catch (error) {
        console.log(`[FAIL] ${username} failed the secret tests.`);
        console.log(error.stdout || error.message);
        return res.status(400).send(`STATUS=FAILURE\nMESSAGE=${error.message.replace(/\n/g, ' ')}\n`);
    }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`🚀 Central Judge Server blasting off on port ${PORT}...`);
});
