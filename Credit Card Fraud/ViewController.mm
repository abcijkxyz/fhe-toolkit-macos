//
//  ViewController.m
//  Credit Card Fraud
//
//  Created by boland on 7/21/20.
//  Copyright © 2020 IBM. All rights reserved.
//

#import "ViewController.h"

#include <iostream>

#include "HelibCkksContext.h"
#include "HelibConfig.h"
#include "FileUtils.h"
#include "SimpleNeuralNetPlain.h"
#include "SimpleNeuralNet.h"
#include "SimpleTrainingSet.h"
#include "CipherMatrixEncoder.h"
#include <string>

using namespace std;

std::string prependBundlePathOnFilePath(const char *fileName) {
      return [[NSBundle mainBundle] pathForResource:[NSString stringWithUTF8String: fileName] ofType: nil].UTF8String;
}

// define names of files to be used for saving and loading of HE contexts and encrypted model
const string outDir = "./credit_card_fraud_output";
const string clientContext = outDir + "/client_context.bin";
const string serverContext = outDir + "/server_context.bin";
const string encryptedModelFile = outDir + "/encrypted_model.bin";

// paths from which to load the plain model, samples and lebels
//const string plainModelFile  = prependBundlePathOnFilePath("model_42098.h5");
const H5std_string plainModelFile(prependBundlePathOnFilePath("model_42098.h5"));
const string plainSamplesFile  = "./data/x_test.h5";
const string plainLabelsFile  = "./data/y_test.h5";

/*
 * define the number of slots in each ciphertext object.
 * a value of 8192 slots produces a security level of -10 with a relatively short setup time and small model.
 * a value of 16384 slots produces a security level of 88.
 * a value of 32768 slots produces a security level of 287 with a relatively long setup time and big model.
 * */
int numSlots = 512;

// define the number of samples in each batch to be all the available slots
int batchSize = numSlots;

int numBatches = -1; // to be overwritten when loading the data set
double classificationThreshold = 0.5; // used to separate positive from negative samples

/*
 * create an HELIB context for both the client and the server, and save contexts into files
 * client context contains a secret key while server context does not
 * */
void createContexts() {
  
  cout << "Initalizing HElib . . ." << endl;
  HelibConfig conf;
  conf.m=numSlots*2*2;
  conf.r=50;
  conf.L=700;

  HelibCkksContext he;
  he.init(conf);
  he.printSignature(cout);

  cout << "Clearing " << outDir << endl;
  FileUtils::createCleanDir(outDir);
  cout << "Saving client side context to " << clientContext << endl;
  bool withSecretKey = true;
  he.saveToFile(clientContext, withSecretKey); // save client context

  cout << "Saving server side context to " << serverContext << endl;
  withSecretKey = false;
  he.saveToFile(serverContext, withSecretKey); // save server context
}


/*
 * a class to represent client-side operations.
 * the client is the one loading the plain model, plain samples and plain labels.
 * the client encrypts the model and samples and save the encrypted elements into files,
 * to be processed by the server. the server predictions are then loaded by the client to be
 * decrypted and analyzed.
 * */
class Client {

    HelibCkksContext he;

    SimpleTrainingSet ts;

    std::vector<DoubleMatrixArray> allPredictions;

    int currentBatch;

public:

    Client() : ts(batchSize), currentBatch(0) {
    }

  void init(){
        cout << "CLIENT: loading client side context . . ." << endl;
        he.loadFromFile(clientContext); // load context from file
        he.printSignature(cout);

        cout << "CLIENT: loading plain model . . ." << endl;
        // parse the plain model from h5 file, use it to init an object of plain NN
        SimpleNeuralNetPlain plainNet;
        H5Parser parser(plainModelFile);
        plainNet.loadh5(parser, std::vector<string>{"dense_1", "dense_2", "dense_3"},
                std::vector<int>{29, 20, 5, 1}, batchSize);

        cout << "CLIENT: encrypting plain model . . ." << endl;
        // use the plain NN to init an object of encrypted HE NN
        SimpleNeuralNet netHe(he);
        netHe.initFromNet(plainNet);

        cout << "CLIENT: saving encrypted model . . ." << endl;
        // saving the encrypted NN to file to be later used by the server
        ofstream ofs(encryptedModelFile, ios::out | ios::binary);
        netHe.save(ofs);
        ofs.close();

        cout << "CLIENT: loading plain samples . . ." << endl;
        // load plain samples from h5 file, will be later encrypted and saved
      ts.loadFromH5(plainSamplesFile, "x_test", plainLabelsFile, "y_test");
      numBatches = ts.getNumBatches();
  }

  void encryptAndSaveSamples(int batch, const string& encryptedSamplesFile){
    const CipherMatrixEncoder encoder(he);
    const CTile prototype(he);

        cout << "CLIENT: encrypting plain samples . . ." << endl;
    const DoubleMatrixArray plainSamples = ts.getSamples(batch);
    CipherMatrix encryptedSamples(prototype);
    encoder.encodeEncrypt(encryptedSamples, plainSamples.getTensor());

        cout << "CLIENT: saving encrypted samples . . ." << endl;
    std::ofstream ofs(encryptedSamplesFile, ios::out | ios::binary);
    encryptedSamples.save(ofs);
    ofs.close();
  }

  void decryptPredictions(const string& encryptedPredictionsFile){
    const CipherMatrixEncoder encoder(he);
    const CTile prototype(he);

        cout << "CLIENT: loading encrypted predictions . . ." << endl;
    CipherMatrix encryptedPredictions(prototype);
      std::ifstream ifs(encryptedPredictionsFile, ios::in | ios::binary);
      encryptedPredictions.load(ifs);
      ifs.close();

        cout << "CLIENT: decrypting predictions . . ." << endl;
      DoubleMatrixArray plainPredictions(encoder.decryptDecodeDouble(encryptedPredictions));
      allPredictions.push_back(plainPredictions);
  }

  void assessResults(){

        cout << "CLIENT: assessing results so far . . ." << endl;

    int truePositives = 0;
    int trueNegatives = 0;
    int falsePositives = 0;
    int falseNegatives = 0;
    currentBatch++;

        // go over the predictions of each batch and count hits
    for(int i=0; i<currentBatch; ++i){

        const DoubleMatrixArray labels = ts.getLabels(i); // these are the batch's true labels
        const DoubleMatrixArray predictions = allPredictions.at(i); // these are the batch's predictions

        int samplesToCheck = labels.size();
        if(i == numBatches - 1) // last batch may partially be populated with "dummy" labels to ignore
            samplesToCheck = ts.getNumSamples() - (batchSize * (numBatches - 1));

        for(int j=0; j<samplesToCheck; ++j){
            int label = labels.getMat(j).get(0, 0);
            // determines the classification of the current samples based on the prediction made by the server
            // and the threshold defined
            int classification = (predictions.getMat(j).get(0, 0) > classificationThreshold ? 1 : 0);

            if(classification == label && classification == 1)
                truePositives++;
            else if(classification == label && classification == 0)
                trueNegatives++;
            else if(classification != label && classification == 1)
                falsePositives++;
            else
                falseNegatives++;
        }
    }

    double precision = ((double) truePositives / (truePositives + falsePositives));
    double recall = ((double) truePositives / (truePositives + falseNegatives));
    double f1Score = (2 * precision * recall) / (precision + recall);

    cout << endl;
    cout << "|---------------------------------------------|" << endl;
    cout << "|                       |    True condition   |" << endl;
    cout << "|                       ----------------------|" << endl;
    cout << "|                       | Positive | Negative |" << endl;
    cout << "|---------------------------------------------|" << endl;
    cout << "| Predicted  | Positive |" << setw(8) << truePositives << "  |" << setw(8) << falsePositives << "  |" << endl;
    cout << "|            |--------------------------------|" << endl;
    cout << "| condition  | Negative |" << setw(8) << falseNegatives << "  |" << setw(8) << trueNegatives << "  |" << endl;
    cout << "|---------------------------------------------|" << endl;
    cout << endl;
    cout << "Precision: " << precision << endl;
    cout << "Recall: " << recall << endl;
    cout << "F1 score: " << f1Score << endl;
  }

};

/*
 * a class to represent server-side operations.
 * the server is the one loading the encrypted model and samples.
 * the server runs the encrypted samples through the encrypted model to obtain encrypted predictions
 * and save the encrypted predictions into files, to be decrypted and analyzed by the client.
 * */
class Server {

    HelibCkksContext he;

    shared_ptr<SimpleNeuralNet> encryptedNet;

public:

    void init(){
        cout << "SERVER: loading server side context . . ." << endl;
        he.loadFromFile(serverContext); // load context from file
        he.printSignature(cout);

        cout << "SERVER: loading encrypted model . . ." << endl;
        // load the encrypted model from file that was saved by the client into an encrypted NN object
        ifstream ifs(encryptedModelFile, ios::in | ios::binary);
        SimpleNeuralNet net(he);
        net.load(ifs);
        ifs.close();

        encryptedNet = make_shared<SimpleNeuralNet>(net);
    }

    void processEncryptedSamples(const string& encryptedSamplesFile, const string& encryptedPredictionsFile){
    const CipherMatrixEncoder encoder(he);
    const CTile prototype(he);

        cout << "SERVER: loading encrypted samples . . ." << endl;
        // load a batch of encrypted samples from file that was saved by the client
    CipherMatrix encryptedSamples(prototype);
      std::ifstream ifs(encryptedSamplesFile, ios::in | ios::binary);
      encryptedSamples.load(ifs);
      ifs.close();

        cout << "SERVER: predicting over encrypted samples . . ." << endl;
    CipherMatrix encryptedPredictions(prototype);
      encryptedNet->predict(encryptedSamples, encryptedPredictions);

        cout << "SERVER: saving encrypted predictions . . ." << endl;
        // save predictions to be later loaded by the client
      std::ofstream ofs(encryptedPredictionsFile, ios::out | ios::binary);
    encryptedPredictions.save(ofs);
    ofs.close();
    }

};



@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    cout << "*** Starting inference demo ***" << endl;

    // creating HELIB context for both client and server, save them to files
    createContexts();
    
    // init client
    Client client;
    client.init();
    
    //sample server init
    Server server;
    server.init();

   
}


- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];

    // Update the view, if already loaded.
}


@end